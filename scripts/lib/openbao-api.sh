# shellcheck shell=bash
#
# Call OpenBao's HTTP API with the root token, without ever putting it on argv.
#
# WHY THIS EXISTS
#
# openbao-adopt-jwt-mount.sh inlined this exact pattern -- mktemp under umask
# 077, printf a curl `-K` config file, escape `"` and `\`, remove it with a
# trap baked at trap-SET time -- to keep OpenBao's root token, the single
# highest-value credential in this design, out of `ps`/`/proc/<pid>/cmdline`.
# scripts/zitadel-oidc-clients.sh's reconcile_openbao_oidc (#2045) needs the
# same calls, and copying the block a second time is exactly the shape this
# repo has already paid for once -- see cloud-secret-store.sh's own header.
# One copy of the root-token handling, here.
#
# Source this and set CLOUD/REGION (or GCP_PROJECT), the way
# scripts/lib/cloud-secret-store.sh expects, then:
#
#   umask 077
#   OPENBAO_TOKEN_CONFIG="$(mktemp -t openbao-api-curl.XXXXXX)"
#   trap 'rm -f "$OPENBAO_TOKEN_CONFIG"' EXIT
#   openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" openbao/cloud-native-ref/tokens/root
#   OPENBAO_URL=... OPENBAO_CA_FILE=... openbao_req GET sys/auth
#
# The umask, the mktemp and the trap stay the CALLER's, deliberately: they must
# live in whatever scope already owns the caller's own EXIT trap, so this
# library never overwrites it (bash keeps one EXIT trap per shell, not a
# stack -- the same reasoning store_write in cloud-secret-store.sh documents
# for its own temp files).

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/cloud-secret-store.sh"

# Write a curl `-K` config file holding the root token as an X-Vault-Token
# header. Reads the token from the cloud secret store via store_read (the
# caller's CLOUD/REGION), under the same shape openbao-adopt-jwt-mount.sh and
# zitadel-oidc-clients.sh already read: `.token // .root_token // empty`.
#
# Returns 1, and writes nothing to $1, on an empty token -- a wrong guess here
# would otherwise reach the caller as a confusing 403 from OpenBao rather than
# "the secret was unreadable or empty".
openbao_token_config_write() {
    local file="$1" secret_name="$2" raw token escaped
    raw="$(store_read "$secret_name")"
    token="$(printf '%s' "$raw" | jq -r '.token // .root_token // empty' 2>/dev/null)"
    [ -n "$token" ] || return 1

    escaped="${token//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf 'header = "X-Vault-Token: %s"\n' "$escaped" > "$file"
}

# GET/POST/LIST/... OpenBao's API. Reads OPENBAO_URL, OPENBAO_CA_FILE and
# OPENBAO_TOKEN_CONFIG from the caller. TLS is always verified: never `-k`.
openbao_req() {
    local method="$1" path="$2"
    shift 2
    curl -fsS --cacert "$OPENBAO_CA_FILE" -K "$OPENBAO_TOKEN_CONFIG" \
        -X "$method" "${OPENBAO_URL}/v1/${path}" "$@"
}
