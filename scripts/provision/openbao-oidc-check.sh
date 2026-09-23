#!/usr/bin/env bash
#
# Post-deploy check (design E, #2045): prove OpenBao's auth/oidc client agrees
# with the secret store AND with ZITADEL itself, and fail loudly -- never
# silently -- when it doesn't.
#
# WHY THIS EXISTS
#
# scripts/provision/zitadel-oidc-clients.sh's reconcile_openbao_oidc heals the config
# and role after every sync, but nothing proves it actually worked: a
# reconcile that silently never ran (--openbao-url never wired for this
# cluster) or one whose failure got missed leaves OpenBao pointed at a client
# id ZITADEL forgot on its last restore. The symptom is "SSO worked
# yesterday", days after the rebuild that caused it. A later task wires this
# as stage5 of the deploy, so the failure surfaces the moment the drift is
# introduced instead.
#
# THE THREE SOURCES OF TRUTH, and where drift between them shows up:
#   * the secret store's "openbao-oidc" key -- what ZITADEL issued, last time
#     the reconcile converged;
#   * OpenBao's own auth/oidc/config and auth/oidc/role/default -- what
#     OpenBao actually uses today;
#   * ZITADEL itself -- whether the id OpenBao is using still authenticates
#     anything. The id comparison alone cannot prove this: a stale client
#     that happens to equal a stale copy in the store would pass every id
#     check and still fail login (design risk R6). The liveness probe below
#     is what catches that.
#
# EXIT CODES
#   0  consistent, or not bootstrapped at all (no secret AND no mount -- a
#      cluster that has never run the management apply).
#   1  a definite, nameable problem. The message names the fix.
#   2  cannot tell: OpenBao unreachable, the root token unreadable, or the
#      liveness probe still inconclusive after PROBE_ATTEMPTS tries -- no
#      auth_url, or a first hop answering neither 302 nor 400. T0, the
#      live spike that would have measured those two codes against a real
#      ZITADEL, never ran -- no cluster was reachable when this was written
#      (plan ruling on T0) -- so until the first live run, 302/400 are an
#      informed guess, not a measured fact. Exit 2 still fails the stage5
#      job; it is not a pass.
#
# Prints ids only. Never the client secret or the root token.
#
# Usage:
#   openbao-oidc-check.sh --url <url> --root-token-secret-name <id> \
#       --ca-file <path> --cloud aws|gcp [--region <region>] [--project <id>] \
#       [--oidc-secret openbao-oidc] --redirect-uri <uri>

set -o errexit
set -o nounset
set -o pipefail

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/../lib/cloud-secret-store.sh"
# shellcheck source=scripts/lib/openbao-api.sh
. "$(dirname "$0")/../lib/openbao-api.sh"

OPENBAO_URL=""
OPENBAO_ROOT_TOKEN_SECRET=""
OPENBAO_CA_FILE=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
OIDC_SECRET="openbao-oidc"  # pragma: allowlist secret -- a store KEY name, not a secret value
REDIRECT_URI=""
# OpenBao's role. Not a flag: oidc.tf's vault_jwt_auth_backend_role.oidc_default
# pins role_name to "default" the same way it pins the mount path (see below),
# and reconcile_openbao_oidc rotates that same role -- nothing on the platform
# creates a second one.
ROLE="default"
# Where the full recovery command lives. Printing it here instead would mean a
# second copy of IDP_URL, PRIVATE_DOMAIN and the --openbao-* flags, and a
# partial one fails -- or, with a wrong PRIVATE_DOMAIN, rewrites every app's
# redirect URIs.
RECOVERY_DOC='website/content/docs/platform/security/openbao.md, section "OIDC client rotation"'
# The liveness probe's retry budget. Only the probe retries: everything before
# it compares values already at rest, so a second read would say the same.
PROBE_ATTEMPTS=5
RETRY_SLEEP="${OPENBAO_CHECK_RETRY_SLEEP:-10}"

usage() {
    cat <<'EOF' >&2
Usage: openbao-oidc-check.sh --url <url> --root-token-secret-name <id> \
    --ca-file <path> --cloud aws|gcp [--region <region>] [--project <id>] \
    [--oidc-secret openbao-oidc] --redirect-uri <uri>

Exit 0: consistent, or not bootstrapped yet.
Exit 1: a definite problem -- the message names the fix.
Exit 2: cannot tell (OpenBao unreachable, the root token unreadable, or the
liveness probe still inconclusive after its retries).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --url)                    OPENBAO_URL="$2"; shift 2 ;;
        --root-token-secret-name) OPENBAO_ROOT_TOKEN_SECRET="$2"; shift 2 ;;
        --ca-file)                OPENBAO_CA_FILE="$2"; shift 2 ;;
        --cloud)                  CLOUD="$2"; shift 2 ;;
        --region)                 REGION="$2"; shift 2 ;;
        --project)                GCP_PROJECT="$2"; shift 2 ;;
        --oidc-secret)            OIDC_SECRET="$2"; shift 2 ;;
        --redirect-uri)           REDIRECT_URI="$2"; shift 2 ;;
        -h|--help)                usage; exit 0 ;;
        *)                        echo "unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$OPENBAO_URL" ]               || { echo "--url is required" >&2; usage; exit 2; }
[ -n "$OPENBAO_ROOT_TOKEN_SECRET" ] || { echo "--root-token-secret-name is required" >&2; usage; exit 2; }
[ -n "$OPENBAO_CA_FILE" ]           || { echo "--ca-file is required" >&2; usage; exit 2; }
[ -f "$OPENBAO_CA_FILE" ]           || { echo "--ca-file ${OPENBAO_CA_FILE} not found" >&2; exit 2; }
case "$CLOUD" in
    aws|gcp) ;;
    *) echo "--cloud must be aws or gcp" >&2; usage; exit 2 ;;
esac
[ -n "$REDIRECT_URI" ] || { echo "--redirect-uri is required" >&2; usage; exit 2; }

# Everything below reads the store's raw payload, which carries the client
# secret alongside the id (only the id is ever pulled out of it). One function
# so `local -; set +x` guards the whole thing, the same defence
# reconcile_openbao_oidc in zitadel-oidc-clients.sh uses for the same reason:
# an operator debugging a stuck stage5 job under `bash -x` must not get the
# secret traced to their terminal.
check() {
    local -
    set +x

    local secret_present=false mount_present="" auth_json mount probe=0
    local stored stored_id cfg_json role_json cfg have_id have_aud want_aud
    local token_file auth_body resp url hop code location err attempt=0 transient=""

    # Only a not-found answer means absent. Any other failed read, taken as
    # absent, would pass a stranded platform as "not bootstrapped" or warn that
    # an apply will destroy a mount it would not (#2082).
    store_probe "$OIDC_SECRET" || probe=$?
    case "$probe" in
        0) secret_present=true ;;
        1) secret_present=false ;;
        *)
            echo "[FAILED ] cannot tell -- cannot read ${OIDC_SECRET} from the ${CLOUD} secret store: ${STORE_PROBE_ERR}" >&2
            exit 2 ;;
    esac

    token_file="$(umask 077 && mktemp -t openbao-oidc-check-curl.XXXXXX)" || exit 2
    # shellcheck disable=SC2064
    trap "rm -f '$token_file'" EXIT
    if ! openbao_token_config_write "$token_file" "$OPENBAO_ROOT_TOKEN_SECRET"; then
        echo "[FAILED ] cannot tell -- no root token readable from ${OPENBAO_ROOT_TOKEN_SECRET}" >&2
        exit 2
    fi
    OPENBAO_TOKEN_CONFIG="$token_file"

    # Only a mount map that lacks oidc/ means "no mount". An error, an empty
    # body, `null` or `{}` says nothing about the mount -- reading it as "no
    # mount" would report a stale, unreachable OpenBao as first bootstrap.
    if ! auth_json="$(openbao_req GET sys/auth 2>&1)"; then
        echo "[FAILED ] cannot tell -- cannot reach OpenBao at ${OPENBAO_URL}: ${auth_json}" >&2
        exit 2
    fi
    mount="$(jq -r '.data | objects | has("oidc/")' <<< "$auth_json" 2>/dev/null)" || mount=""
    case "$mount" in
        true)  mount_present=true ;;
        false) mount_present=false ;;
        *)
            echo "[FAILED ] cannot tell -- sys/auth returned no mount map: ${auth_json:-<empty body>}" >&2
            exit 2 ;;
    esac

    if [ "$secret_present" = false ] && [ "$mount_present" = false ]; then
        echo "[ok     ] no ${OIDC_SECRET} secret and no oidc/ mount -- OpenBao OIDC not bootstrapped yet"
        exit 0
    fi
    if [ "$secret_present" = true ] && [ "$mount_present" = false ]; then
        echo "[FAILED ] ${OIDC_SECRET} is in the store but OpenBao has no oidc/ auth mount yet."
        echo "          First bootstrap: with ZITADEL up, apply the management stack once:"
        echo "            terramate -C opentofu/aws/openbao/management script run deploy"
        exit 1
    fi
    if [ "$secret_present" = false ] && [ "$mount_present" = true ]; then
        echo "[FAILED ] OpenBao already has an oidc/ auth mount, but ${OIDC_SECRET} is not in the store."
        echo "          The next management apply has no client id to ignore_changes onto, and will DESTROY the mount."
        echo "          Run the sync in ${RECOVERY_DOC} to (re)create ${OIDC_SECRET} first."
        exit 1
    fi

    stored="$(store_read "$OIDC_SECRET")" || stored=""
    stored_id="$(jq -r '.client_id // empty' <<< "$stored" 2>/dev/null)" || stored_id=""
    if [ -z "$stored_id" ]; then
        echo "[FAILED ] cannot tell -- ${OIDC_SECRET} has no client_id" >&2
        exit 2
    fi

    if ! cfg_json="$(openbao_req GET auth/oidc/config 2>&1)"; then
        echo "[FAILED ] cannot tell -- cannot read auth/oidc/config: ${cfg_json}" >&2
        exit 2
    fi
    if ! role_json="$(openbao_req GET "auth/oidc/role/${ROLE}" 2>&1)"; then
        echo "[FAILED ] cannot tell -- cannot read auth/oidc/role/${ROLE}: ${role_json}" >&2
        exit 2
    fi
    cfg="$(jq -ce '.data | objects' <<< "$cfg_json" 2>/dev/null)" || {
        echo "[FAILED ] cannot tell -- auth/oidc/config returned no data: ${cfg_json}" >&2
        exit 2
    }
    have_id="$(jq -r '.oidc_client_id // ""' <<< "$cfg")" || have_id=""
    have_aud="$(jq -ce '.data.bound_audiences // [] | arrays' <<< "$role_json" 2>/dev/null)" || {
        echo "[FAILED ] cannot tell -- auth/oidc/role/${ROLE} returned no audience array: ${role_json}" >&2
        exit 2
    }
    want_aud="$(jq -cn --arg id "$stored_id" '[$id]')" || exit 2

    if [ "$have_id" != "$stored_id" ] || [ "$have_aud" != "$want_aud" ]; then
        echo "[FAILED ] OpenBao's OIDC client does not match the store."
        echo "          store:            ${stored_id}"
        echo "          auth/oidc/config: ${have_id:-<none>}"
        echo "          role audience:    ${have_aud}"
        echo "          Fix: run the sync in ${RECOVERY_DOC}."
        exit 1
    fi

    # The id agrees everywhere OpenBao and the store can be asked -- but a
    # rebuild can restore ZITADEL from a seed OLDER than the store (design
    # risk R6), pairing a client id ZITADEL genuinely does not know with a
    # store that still (wrongly) agrees. auth_url is the one call that goes
    # all the way to ZITADEL: a known client 302s to its login page; an
    # unknown one -- or a known one asked for a redirect_uri it never
    # registered -- 400s. A 302 straight back to the redirect_uri is ZITADEL
    # refusing the request with ?error=, not accepting it.
    #
    # Only a 302 or a 400 is definite. Everything else can be ZITADEL still
    # starting mid-rebuild, so it is retried before it is called "cannot
    # tell". OpenBao v2.6.2 answers 200 with an EMPTY auth_url when it cannot
    # fetch the discovery document -- the same answer it gives for a
    # redirect_uri the role does not allow, so an empty URL that persists
    # stays exit 2: this script cannot tell the two apart.
    auth_body="$(jq -cn --arg r "$ROLE" --arg u "$REDIRECT_URI" '{role: $r, redirect_uri: $u}')" || exit 2
    while [ "$attempt" -lt "$PROBE_ATTEMPTS" ]; do
        attempt=$((attempt + 1))
        if [ "$attempt" -gt 1 ]; then sleep "$RETRY_SLEEP"; fi

        if ! resp="$(printf '%s' "$auth_body" | openbao_req POST auth/oidc/oidc/auth_url --data-binary @- 2>&1)"; then
            transient="cannot reach auth/oidc/oidc/auth_url: ${resp}"
            continue
        fi
        url="$(jq -r '.data.auth_url // empty' <<< "$resp" 2>/dev/null)" || url=""
        if [ -z "$url" ]; then
            transient="auth/oidc/oidc/auth_url returned no auth_url for role ${ROLE}: OpenBao cannot fetch ZITADEL's discovery document, or the redirect_uri is not in the role's allowed_redirect_uris"
            continue
        fi

        # The authorize URL points at ZITADEL, not OpenBao: no --cacert (that
        # would be OpenBao's CA, wrong issuer entirely) and no -L, since the
        # FIRST hop's status code is what tells known from unknown. TLS is
        # still verified against the system trust store -- never -k -- which
        # is correct here: ZITADEL's route is public (design fact 1's topology
        # table), so its certificate chains to a public CA.
        if ! hop="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$url" 2>&1)"; then
            transient="cannot reach the authorize URL's first hop: ${hop}"
            continue
        fi
        code="${hop%% *}" location="${hop#* }"
        case "$code" in
            302)
                case "$location" in
                    "$REDIRECT_URI"*)
                        # The error only: the rest of the query carries OpenBao's state.
                        err="$(sed -nE 's/.*[?&](error=[^&]*).*/\1/p' <<< "$location")"
                        echo "[FAILED ] ZITADEL redirected back with an error (${err:-no error parameter}) instead of to its login page, for client ${have_id}" >&2
                        exit 1 ;;
                esac
                echo "[ok     ] OpenBao's OIDC client ${have_id} matches the store, and ZITADEL accepts it (first hop 302)"
                exit 0 ;;
            400)
                echo "[FAILED ] the authorize URL's first hop returned 400 -- ZITADEL does not know client ${have_id} (App.NotFound)," >&2
                echo "          or the client does not list ${REDIRECT_URI} among its redirect URIs" >&2
                exit 1 ;;
            *)
                transient="the authorize URL's first hop returned ${code}, neither 302 nor 400."$'\n'"          T0, the live spike, never ran: treat 302/400 as unverified until the first live run." ;;
        esac
    done
    echo "[FAILED ] cannot tell after ${PROBE_ATTEMPTS} attempts -- ${transient}" >&2
    exit 2
}

check
