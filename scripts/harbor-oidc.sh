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
HARBOR_PASSWORD="$(kubectl get secret harbor-admin-password -n tooling \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)"
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

if [ "$cur_mode" = "oidc_auth" ] && [ "$cur_client" = "$client_id" ] && [ "$cur_endpoint" = "$endpoint" ]; then
    echo "[skip   ] Harbor already points at this ZITADEL client"
    exit 0
fi

if [ "$APPLY" != "true" ]; then
    echo "[dry-run] would set auth_mode=oidc_auth, endpoint=${endpoint}, client=${client_id}"
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
payload="$(jq -n \
    --arg name "$OIDC_DISPLAY_NAME" \
    --arg ep "$endpoint" \
    --arg id "$client_id" \
    --arg sec "$client_secret" \
    '{
        auth_mode: "oidc_auth",
        oidc_name: $name,
        oidc_endpoint: $ep,
        oidc_client_id: $id,
        oidc_client_secret: $sec,
        oidc_scope: "openid,profile,email,offline_access",
        oidc_groups_claim: "groups",
        oidc_user_claim: "preferred_username",
        oidc_auto_onboard: true,
        oidc_verify_cert: true
     }')"

http="$(jq -n --argjson b "$payload" '$b' \
    | api PUT /configurations -d @- -o /dev/null -w '%{http_code}')"

case "$http" in
    200|204)
        echo "[applied] auth_mode=oidc_auth, client ${client_id}" ;;
    *)
        echo "[FAILED ] Harbor returned HTTP ${http} for PUT /configurations" >&2
        exit 1 ;;
esac

verify="$(api GET /configurations 2>/dev/null || true)"
echo "now:      auth_mode=$(jq -r '.auth_mode.value // "?"' <<< "$verify") endpoint=$(jq -r '.oidc_endpoint.value // "?"' <<< "$verify")"

echo
echo "The ZITADEL client's redirect URI must be ${HARBOR_URL}/c/oidc/callback --"
echo "zitadel-oidc-clients.sh registers exactly that."
