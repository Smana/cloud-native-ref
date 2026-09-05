#!/usr/bin/env bash
# Adopt this cluster's JWT auth mount into the calling stack's OpenTofu state,
# when OpenBao already holds it and the state does not.
#
# WHY THIS EXISTS
# ---------------
# The lineage restores OpenBao's whole storage from a snapshot on every deploy
# (ADR-0033). `jwt/<cluster>` and its roles live in that storage, so they come
# back. But the stack that OWNS them -- opentofu/{aws/eks,gcp/gke}/configure --
# is destroyed on every teardown, so its state does not. On the next deploy
# OpenTofu therefore tries to CREATE a mount the snapshot already restored:
#
#   POST /v1/sys/auth/jwt/aws-0 -> 400 "path is already in use at jwt/aws-0/"
#
# That is not merely a collision to route around. The restored mount is STALE:
# its `oidc_discovery_url` names the OIDC issuer of the cluster that was
# destroyed, and an EKS/GKE issuer id changes on every rebuild. Measured
# 2026-09-05:
#
#   restored mount : .../id/B5AC3FF6951830AB3A25A56136DA8907   (gone)
#   new cluster    : .../id/A0F8FD418B41D2BABB156BCFBF4BF5E2
#
# So every JWT login would fail against it -- cert-manager, External Secrets and
# the snapshot job alike. The 400 is protective: without it the deploy would
# report success and leave an auth method that rejects every token.
#
# Adopting rather than deleting is deliberate. `tofu import` puts the existing
# mount under management and the apply that follows UPDATES its issuer in place,
# which keeps the roles and their bound policies intact. Deleting the mount
# would revoke every token it ever issued and drop the roles with it.
#
# Idempotent and safe on a first deploy: if OpenBao has no such mount, this
# exits 0 and OpenTofu creates it normally.
set -euo pipefail

CLUSTER_NAME=""
OPENBAO_URL=""
ROOT_TOKEN_SECRET_NAME=""
CA_FILE=""
CLOUD="aws"
REGION=""
PROJECT=""

usage() {
    echo "Usage: $0 --cluster-name <name> --url <url> --root-token-secret-name <id> [options]"
    echo "  --ca-file <path>     CA chain to verify OpenBao with"
    echo "  --cloud <aws|gcp>    Secret backend holding the root token (default: aws)"
    echo "  --region <region>    AWS region"
    echo "  --project <id>       GCP project"
    echo "  -- <tofu args...>    Passed to every 'tofu import' (the -var flags the"
    echo "                       apply uses; import needs the same required variables)"
}

# Everything after `--` goes to `tofu import`. Required variables with no
# default (gateway_api_version and friends) are supplied to the apply as -var
# flags, and `tofu import` evaluates the same root module, so it needs them too
# -- without them it stops at "No value for required variable" before it reaches
# the resource.
TOFU_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --)                        shift; TOFU_ARGS="$*"; break ;;
        --cluster-name)            CLUSTER_NAME="$2"; shift 2 ;;
        --url)                     OPENBAO_URL="$2"; shift 2 ;;
        --root-token-secret-name)  ROOT_TOKEN_SECRET_NAME="$2"; shift 2 ;;
        --ca-file)                 CA_FILE="$2"; shift 2 ;;
        --cloud)                   CLOUD="$2"; shift 2 ;;
        --region)                  REGION="$2"; shift 2 ;;
        --project)                 PROJECT="$2"; shift 2 ;;
        -h|--help)                 usage; exit 0 ;;
        *)                         echo "unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[ -n "$CLUSTER_NAME" ] && [ -n "$OPENBAO_URL" ] && [ -n "$ROOT_TOKEN_SECRET_NAME" ] || {
    echo "--cluster-name, --url and --root-token-secret-name are required" >&2; usage; exit 1; }

# Import one address, treating "already managed" as success.
#
# The pre-checks below use `tofu state list`, and relying on that ALONE proved
# fragile: a run whose state already held the mount still reached the import and
# failed the whole deploy with "Resource already managed by OpenTofu". Whatever
# made that listing come back empty, the outcome must not be a failed deploy --
# adopting something already adopted is a no-op, not an error. So the import's
# own answer is the authority and the listing is only a fast path.
try_import() {
    _ti_addr="$1"; _ti_id="$2"; _ti_out=""
    # shellcheck disable=SC2086 # TOFU_ARGS is a deliberate word-split of -var flags
    if _ti_out=$(tofu import -input=false -var-file=variables.tfvars ${TOFU_ARGS} "$_ti_addr" "$_ti_id" 2>&1); then
        echo "    imported ${_ti_addr}"
        return 0
    fi
    if printf '%s' "$_ti_out" | grep -q 'already managed by OpenTofu'; then
        echo "    ${_ti_addr} was already managed -- nothing to do"
        return 0
    fi
    printf '%s\n' "$_ti_out" >&2
    return 1
}

MOUNT="jwt/${CLUSTER_NAME}"

# Already managed? Then there is nothing to adopt -- this is an ordinary
# re-deploy of a stack whose state survived.
if tofu state list 2>/dev/null | grep -qx 'vault_jwt_auth_backend.cluster'; then
    echo "==> ${MOUNT} is already in this stack's state; nothing to adopt."
    exit 0
fi

# Read the lineage's root token. Failing to read it is NOT "no mount": that
# conflation is what this repo's openbao-config.sh argues against at length for
# bucket listings, and the same rule applies here -- proceeding would let
# OpenTofu attempt a create that fails 400 with a confusing message.
if [ "$CLOUD" = "gcp" ]; then
    [ -n "$PROJECT" ] || { echo "--project is required with --cloud gcp" >&2; exit 1; }
    TOKEN=$(gcloud secrets versions access latest --secret="$ROOT_TOKEN_SECRET_NAME" --project "$PROJECT" 2>/dev/null | jq -r '.token // .root_token // empty')
else
    TOKEN=$(aws secretsmanager get-secret-value ${REGION:+--region "$REGION"} --secret-id "$ROOT_TOKEN_SECRET_NAME" --query SecretString --output text 2>/dev/null | jq -r '.token // .root_token // empty')
fi
if [ -z "${TOKEN:-}" ]; then
    echo "ERROR: could not read the root token from ${ROOT_TOKEN_SECRET_NAME}." >&2
    echo "       Refusing to guess whether ${MOUNT} exists -- a wrong guess makes the" >&2
    echo "       apply fail with 'path is already in use', which reads as a bug in this" >&2
    echo "       stack rather than an unreadable secret." >&2
    exit 1
fi

# Does OpenBao hold it? `sys/auth` needs a token, hence the read above.
auth_json=$(curl -fsS ${CA_FILE:+--cacert "$CA_FILE"} \
    -H "X-Vault-Token: ${TOKEN}" "${OPENBAO_URL}/v1/sys/auth" 2>/dev/null) || {
    echo "ERROR: could not list OpenBao's auth mounts at ${OPENBAO_URL}." >&2
    exit 1; }

if ! printf '%s' "$auth_json" | jq -e --arg m "${MOUNT}/" 'has($m)' >/dev/null 2>&1; then
    echo "==> OpenBao has no ${MOUNT}; OpenTofu will create it."
    exit 0
fi

echo "==> OpenBao already holds ${MOUNT} (restored from the lineage snapshot)."
echo "    Importing it so the apply UPDATES its issuer instead of failing to create it."
try_import vault_jwt_auth_backend.cluster "${MOUNT}"

# The roles too. A role create is a PUT and would overwrite silently, which is
# not wrong -- but leaving them unmanaged means the next `tofu destroy` walks
# away from them, and the state then disagrees with OpenBao in the other
# direction. Import what exists; skip what does not.
roles_json=$(curl -fsS ${CA_FILE:+--cacert "$CA_FILE"} \
    -H "X-Vault-Token: ${TOKEN}" -X LIST \
    "${OPENBAO_URL}/v1/auth/${MOUNT}/role" 2>/dev/null) || roles_json=""
if [ -n "$roles_json" ]; then
    for role in $(printf '%s' "$roles_json" | jq -r '.data.keys[]?' 2>/dev/null); do
        if tofu state list 2>/dev/null | grep -qx "vault_jwt_auth_backend_role.cluster\[\"${role}\"\]"; then
            continue
        fi
        echo "    importing role ${role}"
        try_import "vault_jwt_auth_backend_role.cluster[\"${role}\"]" \
            "auth/${MOUNT}/role/${role}" || \
            echo "    (role ${role} not imported; the apply will write it)"
    done
fi

echo "==> Adoption complete. The apply that follows reconciles the issuer."
