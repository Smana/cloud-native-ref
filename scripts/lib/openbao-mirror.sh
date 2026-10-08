# shellcheck shell=bash
#
# Mirror a managed-store secret into the OpenBao path its ExternalSecret reads
# (--mirror-openbao). Shared by zitadel-oidc-clients.sh and zitadel-idp.sh, so
# there is one copy of the merge rule and the failure handling. Callers set
# MIRROR_OPENBAO, OPENBAO_URL, OPENBAO_CA_FILE and OPENBAO_ROOT_TOKEN_SECRET.

# shellcheck source=scripts/lib/openbao-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/openbao-api.sh"
# shellcheck source=scripts/lib/bao-map.sh
. "$(dirname "${BASH_SOURCE[0]}")/bao-map.sh"

# The fields this script owns in a consumer secret: every key merge_secret and
# converge_secret write. Onto an EXISTING OpenBao value the mirror copies only
# these. The rest of a blob belongs to another writer -- seed's
# GF_SECURITY_ADMIN_PASSWORD in grafana-envvars -- and OpenBao's copy of it may
# be newer than the store's (a rotation made in OpenBao), so the mirror never
# overwrites it. An ABSENT path gets the whole payload: `migrate` skips a path
# that exists, so nothing else would ever fill in the rest.
# test-zitadel-oidc-clients-mirror.sh fails when merge_secret writes a key
# missing here.
MIRRORED_FIELDS=(
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
    OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_ISSUER_URL OIDC_SCOPES
    OIDC_VALIDATOR_CLIENT_ID OIDC_VALIDATOR_ISSUER_URL
    clientID clientSecret
    client_id client_secret endpoint
    client-id client-secret cookie-secret project-id
    pat tokenId githubIdpId
)

# Mirror one consumer secret into the OpenBao path its ExternalSecret reads
# (--mirror-openbao): MIRRORED_FIELDS from the store's blob, onto what OpenBao
# holds, or the whole blob when OpenBao holds nothing. Writes only when that
# changes OpenBao's value, so a re-run adds no KV version. Unmapped keys
# (openbao-oidc, headlamp-oauth2-proxy) are read from the managed store; they
# are skipped, and said so. A subshell, like
# reconcile_openbao_oidc, so its temp files and trap stay local. Secrets move
# through stdin and 0700-directory files, never argv.
mirror_to_openbao() (
    # xtrace would print the payload, and the client secret with it.
    set +x
    key="$1"
    [ "${MIRROR_OPENBAO:-false}" = "true" ] || exit 0
    if ! target="$(bao_target_for "$key")"; then
        echo "[skip   ] ${key}: no OpenBao path in scripts/lib/bao-map.sh" >&2
        exit 0
    fi
    mount="${target%%/*}"
    path="${target#*/}"
    # One directory, trapped the moment it exists, so no second mktemp can
    # fail and strand the first. The path is baked in at trap-set time.
    tmp="$(umask 077 && mktemp -d -t openbao-mirror.XXXXXX)" || exit 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    cat > "$tmp/payload" || exit 1
    OPENBAO_TOKEN_CONFIG="$tmp/token"
    if ! openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" "${OPENBAO_ROOT_TOKEN_SECRET:-}"; then
        echo "[FAILED ] ${key} -- no OpenBao root token readable from ${OPENBAO_ROOT_TOKEN_SECRET:-<unset>}" >&2
        exit 1
    fi
    # Only a 404 means "nothing there yet". Any other answer (403, a TLS or CA
    # error, a timeout) must not become an empty merge base. curl's stderr is
    # shown for those: it holds curl's own error line only -- the token is in a
    # -K file and a body goes to -o -- and a 404's "(22)" line is expected.
    absent=false
    code="$(openbao_req GET "${mount}/data/${path}" -o "$tmp/read" -w '%{http_code}' 2>"$tmp/err")" || true
    case "$code" in
        200) jq -ce '.data.data // {} | objects' "$tmp/read" > "$tmp/current" \
                 || { echo "[FAILED ] ${key} -- ${target} is not readable JSON; not overwriting it" >&2; exit 1; } ;;
        404) printf '{}' > "$tmp/current"; absent=true ;;
        *)   echo "[FAILED ] ${key} -- reading ${target} returned HTTP ${code:-none}; not overwriting it" >&2
             cat "$tmp/err" >&2
             exit 1 ;;
    esac
    # Field NAMES go in as --args (none is secret); both values on stdin.
    if ! cat "$tmp/current" "$tmp/payload" | jq -cn --argjson absent "$absent" '
            input as $cur | input as $p |
            (if $absent then $p
             else $cur + ($p | with_entries(select(.key | IN($ARGS.positional[])))) end) as $new |
            if $new == $cur then empty else {data: $new} end' \
            --args "${MIRRORED_FIELDS[@]}" > "$tmp/write"; then
        echo "[FAILED ] ${key} -- could not merge into ${target}; not overwriting it" >&2
        exit 1
    fi
    if [ ! -s "$tmp/write" ]; then
        echo "[ok     ] ${key} -- ${target} already holds these fields"
        exit 0
    fi
    if ! openbao_req POST "${mount}/data/${path}" --data-binary @- < "$tmp/write" >/dev/null; then
        echo "[FAILED ] ${key} -- not mirrored to ${target}" >&2
        exit 1
    fi
    echo "[mirrored] ${key} -> ${target}"
)
