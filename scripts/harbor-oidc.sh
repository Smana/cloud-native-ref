#!/usr/bin/env bash
#
# Point Harbor's login at ZITADEL.
#
# WHY THIS EXISTS
#
# Harbor's authentication mode is not chart configuration. `auth_mode`, the OIDC
# endpoint, the client and the scopes all live in Harbor's DATABASE, written
# through its API at runtime -- so nothing in `tooling/base/harbor/` can express
# them and nothing in git makes them true. On aws-0 they were set by hand in the
# UI, which is why gcp-0 came up on 2026-08-28 with `auth_mode: db_auth` and no
# SSO button, while every manifest looked correct.
#
# Same failure as the Google IdP before scripts/zitadel-idp.sh: configuration
# that exists only because a long-lived cluster happens to hold it.
#
# ORDER MATTERS. This is the SECOND step:
#
#   1. zitadel-oidc-clients.sh sync --cluster <c> --cloud <c> --apply
#        registers the `harbor` OIDC client and writes it to the secret store
#   2. harbor-oidc.sh sync --cluster <c> --cloud <c> --apply
#        reads that client and tells Harbor to use it
#
# Usage:
#   harbor-oidc.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#   harbor-oidc.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
# Dry-run unless --apply. The client secret is never printed.
#
# THE LOCAL ADMIN STILL WORKS. Switching to oidc_auth does not lock you out:
# Harbor keeps the built-in `admin` account usable, which is also how this script
# authenticates. That matters because an OIDC misconfiguration would otherwise be
# unrecoverable through the UI.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/lib/cloud-secret-store.sh"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"

SECRET_KEY="harbor-oidc" # pragma: allowlist secret
OIDC_DISPLAY_NAME="ZITADEL"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --cloud)   CLOUD="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ "$COMMAND" = "sync" ] || { echo "usage: harbor-oidc.sh sync --cluster <name> --cloud <aws|gcp> [--apply]" >&2; exit 2; }
[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

: "${PRIVATE_DOMAIN:?set PRIVATE_DOMAIN, e.g. priv.gcp.ogenki.io}"

HARBOR_URL="https://harbor.${PRIVATE_DOMAIN}"

# Harbor's admin password comes from the CLUSTER, the same way zitadel-idp.sh
# reads ZITADEL's PAT: the chart generates it into a Secret, so the cluster is
# where it is true.
#
# Read in two steps, not one pipeline. Under `set -o errexit -o pipefail`, a
# failing `kubectl` inside `kubectl ... | base64 -d` fails the whole pipeline,
# which fails the assignment, which exits the script BEFORE the emptiness
# check below ever runs -- with kubectl's own stderr suppressed, that's a bare
# `exit 1` and no reason. Same pattern zitadel-pat.sh already reads this way.
_harbor_password_b64="$(kubectl get secret harbor-admin-password -n tooling \
        -o jsonpath='{.data.password}' 2>/dev/null || true)"
HARBOR_PASSWORD=""
[ -n "$_harbor_password_b64" ] && HARBOR_PASSWORD="$(printf '%s' "$_harbor_password_b64" | base64 -d 2>/dev/null || true)"
if [ -z "$HARBOR_PASSWORD" ]; then
    echo "ERROR: could not read tooling/harbor-admin-password from the cluster." >&2
    exit 1
fi

api() {
    local method="$1" path="$2"
    shift 2
    curl -sSk -X "$method" "${HARBOR_URL}/api/v2.0${path}" \
        -u "admin:${HARBOR_PASSWORD}" \
        -H "Content-Type: application/json" \
        "$@"
}

echo "cluster:  ${CLUSTER} (${CLOUD})"
echo "harbor:   ${HARBOR_URL}"
echo

blob="$(store_read "$SECRET_KEY" || true)"
if [ -z "$blob" ]; then
    echo "[FAILED ] ${SECRET_KEY} not found in the ${CLOUD} store." >&2
    echo "           Run zitadel-oidc-clients.sh first -- it registers the client" >&2
    echo "           and writes it there. This script only applies it." >&2
    exit 1
fi

client_id="$(jq -r '.client_id // empty' <<< "$blob")"
client_secret="$(jq -r '.client_secret // empty' <<< "$blob")"
endpoint="$(jq -r '.endpoint // empty' <<< "$blob")"
if [ -z "$client_id" ] || [ -z "$client_secret" ] || [ -z "$endpoint" ]; then
    echo "[FAILED ] ${SECRET_KEY} is missing client_id/client_secret/endpoint" >&2
    exit 1
fi

current="$(api GET /configurations 2>/dev/null || true)"
cur_mode="$(jq -r '.auth_mode.value // "unknown"' <<< "$current")"
cur_client="$(jq -r '.oidc_client_id.value // ""' <<< "$current")"
cur_endpoint="$(jq -r '.oidc_endpoint.value // ""' <<< "$current")"

echo "current:  auth_mode=${cur_mode} endpoint=${cur_endpoint:-<none>} client=${cur_client:-<none>}"
echo

# Report each field individually -- matching the [ok]/[STALE] convergence
# report zitadel-idp.sh and zitadel-oidc-clients.sh already print elsewhere in
# this repo -- rather than one bundled skip/dry-run line. `oidc_client_secret`
# is NOT compared here: like ZITADEL, Harbor never echoes a stored secret back
# on GET, so there is nothing to read and diff it against. It is rewritten
# unconditionally whenever any of the three fields below are (see the PUT
# below) -- an API constraint, not a gap in this check.
stale=0

if [ "$cur_mode" = "oidc_auth" ]; then
    echo "[ok     ] harbor auth_mode"
else
    echo "[STALE  ] harbor auth_mode: has ${cur_mode}, want oidc_auth"
    stale=1
fi

if [ "$cur_endpoint" = "$endpoint" ]; then
    echo "[ok     ] harbor oidc_endpoint"
else
    echo "[STALE  ] harbor oidc_endpoint: has ${cur_endpoint:-<none>}, want ${endpoint}"
    stale=1
fi

if [ "$cur_client" = "$client_id" ]; then
    echo "[ok     ] harbor oidc_client_id"
else
    echo "[STALE  ] harbor oidc_client_id: has ${cur_client:-<none>}, want ${client_id}"
    stale=1
fi

if [ "$stale" -eq 0 ]; then
    echo
    echo "[ok     ] Harbor already points at this ZITADEL client"
    exit 0
fi

if [ "$APPLY" != "true" ]; then
    echo
    echo "This was a DRY RUN. Re-run with --apply."
    exit 0
fi

# oidc_scope MUST include offline_access. Harbor uses the refresh token to keep a
# CLI/robot session alive, and refuses the configuration without it; ZITADEL
# issues one only when the scope is requested.
#
# oidc_auto_onboard creates the Harbor user on first login, so a Workspace user
# does not need a Harbor account made for them first. oidc_user_claim picks WHICH
# claim becomes the username -- `preferred_username` rather than `email`, because
# Harbor usernames cannot contain some characters valid in an address.
#
# auth_mode is set LAST in this payload for readability only; Harbor applies the
# whole PUT atomically, so a partial switch is not possible.
#
# oidc_client_secret goes in via stdin (-Rs reads it as one raw string, `.` is
# the secret), never as a jq --arg -- argv is world-readable for the life of
# the process via /proc/<pid>/cmdline, and this IS a credential. Same class of
# bug Task 4 fixed in zitadel-idp.sh; this call site had it too until now.
harbor_oidc_payload() {
    local name="$1" ep="$2" id="$3" secret="$4"
    printf '%s' "$secret" | jq -Rs --arg name "$name" --arg ep "$ep" --arg id "$id" \
        '{
            auth_mode: "oidc_auth",
            oidc_name: $name,
            oidc_endpoint: $ep,
            oidc_client_id: $id,
            oidc_client_secret: .,
            oidc_scope: "openid,profile,email,offline_access",
            oidc_groups_claim: "groups",
            oidc_user_claim: "preferred_username",
            oidc_auto_onboard: true,
            oidc_verify_cert: true
         }'
}

payload="$(harbor_oidc_payload "$OIDC_DISPLAY_NAME" "$endpoint" "$client_id" "$client_secret")"

# Piped straight to curl on stdin -- NOT re-parsed through a second
# `jq -n --argjson b "$payload"` hop first. That hop was dead weight (an
# identity transform, `$b`) and, worse, its own argv leak: $payload already
# contains the plaintext secret at this point, and --argjson would have put
# the whole thing on this second process's command line too.
http="$(printf '%s' "$payload" \
    | api PUT /configurations -d @- -o /dev/null -w '%{http_code}')"

case "$http" in
    200|204)
        echo "[applied] auth_mode=oidc_auth, client ${client_id}" ;;
    *)
        echo "[FAILED ] Harbor returned HTTP ${http} for PUT /configurations" >&2
        exit 1 ;;
esac

verify="$(api GET /configurations 2>/dev/null || true)"
echo "now:      auth_mode=$(jq -r '.auth_mode.value // "?"' <<< "$verify") endpoint=$(jq -r '.oidc_endpoint.value // "?"' <<< "$verify") client=$(jq -r '.oidc_client_id.value // "?"' <<< "$verify")"

echo
echo "The ZITADEL client's redirect URI must be ${HARBOR_URL}/c/oidc/callback --"
echo "zitadel-oidc-clients.sh registers exactly that."
