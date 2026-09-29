#!/usr/bin/env bash
# shellcheck disable=SC2034
# (MIRROR_OPENBAO and OPENBAO_ROOT_TOKEN_SECRET are read by the eval'd body of
# mirror_to_openbao(), which static analysis cannot see.)
# requires: jq
#
# --mirror-openbao (GCP parity GP-5): a fresh directory re-registers every client
# each build, and gcp-0's consumers read OpenBao. The mirror merges into the mapped
# path (admin credentials survive), skips unmapped keys, and does nothing unset.
# mirror_to_openbao() is lifted out of the script, so this tests the code that ships.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$REPO_ROOT" || exit 1
S=scripts/provision/zitadel-oidc-clients.sh
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

body="$(sed -n '/^mirror_to_openbao() (/,/^)/p' "$S")"
[ -n "$body" ] || { echo "could not extract mirror_to_openbao() from $S" >&2; exit 1; }
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"
eval "$body"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
openbao_token_config_write() { : >"$1"; }
GET_BODY='{"data":{"data":{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"old"}}}'
GET_CODE=200
openbao_req() {
    printf '%s %s\n' "$1" "$2" >>"$T/calls"
    local method="$1" out=/dev/null
    shift 2
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    case "$method" in
        GET)  printf '%s' "$GET_BODY" >"$out"; printf '%s' "$GET_CODE" ;;
        POST) cat >"$T/body" ;;
    esac
}

MIRROR_OPENBAO=true
OPENBAO_ROOT_TOKEN_SECRET=fixture
printf '%s' '{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' \
  | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars >/dev/null
grep -qx 'POST platform/data/victoria-metrics/grafana-envvars' "$T/calls" \
  && ok "grafana-envvars is written to its mapped path" || bad "grafana-envvars path: $(cat "$T/calls")"
[ "$(jq -c '.data' "$T/body")" = '{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' ] \
  && ok "merged: the admin user kept, the client id replaced" || bad "merge: $(cat "$T/body")"

: >"$T/calls"; rm -f "$T/body"
GET_CODE=404 GET_BODY='{"errors":[]}'
printf '%s' '{"client_id":"new"}' | mirror_to_openbao harbor-oidc >/dev/null
[ "$(jq -c '.data' "$T/body" 2>/dev/null)" = '{"client_id":"new"}' ] \
  && ok "absent path (404): written fresh" || bad "404 case: $(cat "$T/body" 2>/dev/null)"

: >"$T/calls"; rm -f "$T/body"
GET_CODE=403
printf '%s' '{"client_id":"new"}' | mirror_to_openbao harbor-oidc >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$T/body" ] \
  && ok "unreadable path (403): fails and overwrites nothing" || bad "403 case: rc=$rc, wrote $(cat "$T/body" 2>/dev/null)"
GET_CODE=200

: >"$T/calls"
printf '%s' '{"client_id":"x"}' | mirror_to_openbao openbao-oidc
[ ! -s "$T/calls" ] && ok "openbao-oidc (unmapped) never reaches OpenBao" || bad "an unmapped key reached OpenBao"

: >"$T/calls"
MIRROR_OPENBAO=false
printf '%s' '{"a":"b"}' | mirror_to_openbao harbor-oidc
[ ! -s "$T/calls" ] && ok "without --mirror-openbao nothing is written" || bad "wrote without the flag"

grep -q -- '--mirror-openbao) MIRROR_OPENBAO="true"; shift ;;' "$S" && ok "--mirror-openbao is parsed" || bad "--mirror-openbao is not parsed"
[ "$(grep -c 'store_write_and_mirror "\$key"' "$S")" -eq 2 ] \
  && ok "both consumer writes go through store_write_and_mirror" || bad "a consumer write bypasses the mirror"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
