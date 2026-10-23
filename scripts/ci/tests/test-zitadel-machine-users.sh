#!/usr/bin/env bash
# requires: bash jq
# shellcheck disable=SC2034,SC2218,SC2329
# (the lifted functions read globals the harness defines; eval defines them before the calls)
#
# ensure_machine_user: the agent factory's Slack App is a ZITADEL machine user
# (client credentials, no project role). Functions are lifted verbatim with sed, like the
# sibling suites. Every API, store, mirror, curl and kubectl path is a stub: no case reaches a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../provision/zitadel-oidc-clients.sh}"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
load_function() {
    local body
    body="$(sed -n "/^${1}() {/,/^}/p" "$2")"
    [ -n "$body" ] || body="$(sed -n "/^${1}() (/,/^)/p" "$2")"
    [ -n "$body" ] || { echo "could not extract ${1}() from $2" >&2; exit 1; }
    eval "$body"
}
for f in ensure_machine_user stored_client_id stored_client_secret probe_client_credentials cmd_sync; do load_function "$f" "$SRC"; done
eval "$(sed -n '/^MACHINE_USERS=(/,/^)/p' "$SRC")"
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
IDP_URL=https://auth.example; APPLY=true; APP_SUFFIX=""; project_id=proj-1
mirrored_keys=(); failed_mirrors=""
KEY=agents-factory-slack-principal
STORED='{}'; STORE_STATE=0; USERS='{"result":[]}'; ACCEPT=0; WRITE_RC=0
PUT_CLIENT_ID=factory-slack-app   # what ZITADEL answers to PUT .../secret
# The calls the script makes; the new secret is a fixture, never a real credential.
api_or_fail() {
    printf '%s %s %s\n' "$1" "$2" "${4:-}" >>"$T/api"
    case "$1 $2" in
        "POST /management/v1/users/_search") printf '%s' "$USERS" ;;
        "POST /management/v1/users/machine") printf '{"userId":"u-new"}' ;;
        "PUT /management/v1/users/"*"/secret")
            jq -cn --arg id "$PUT_CLIENT_ID" '{clientSecret: "NEWSECRET"} + (if $id == "" then {} else {clientId: $id} end)' ;;  # pragma: allowlist secret
    esac
}
store_probe() { [ "$STORE_STATE" = 0 ] && return 0; STORE_PROBE_ERR="Rate exceeded"; return "$STORE_STATE"; }
store_read() { printf '%s' "$STORED"; }
store_write_and_mirror() { printf '%s' "$1" >"$T/key"; cat >"$T/written"; return "$WRITE_RC"; }
MIRROR_RC=0
mirror_to_openbao() { cat >/dev/null; return "$MIRROR_RC"; }
# Accepts only the client id the fixture says is current: a probe with another id is refused.
probe_client_credentials() { cat >/dev/null; echo "$1" >"$T/probed-as"; [ "$1" = "$VALID_ID" ] || return 1; return "$ACCEPT"; }
VALID_ID=factory-slack-app
kubectl() { echo "kubectl $*" >>"$T/api"; return 1; }
run() { rm -f "$T/api" "$T/key" "$T/written" "$T/probed-as"; : >"$T/api"; mirrored_keys=(); failed_mirrors=""
        out="$(ensure_machine_user factory-slack-app "$KEY" 2>&1)"; rc=$?
        # a subshell loses the appends: rerun the bookkeeping in this shell, output discarded
        mirrored_keys=(); failed_mirrors=""; ensure_machine_user factory-slack-app "$KEY" >/dev/null 2>&1; }
calls() { cut -d' ' -f1,2 "$T/api" | sed 's#users/u-[a-z0-9]*#users/ID#'; }
written() { jq -c . "$T/written" 2>/dev/null || echo none; }

echo "== 1. no user: create it, generate its secret, store the three fields =="
run
check "exit 0" 0 "$rc"
check "calls (the rerun repeats them, so the first three)" "POST /management/v1/users/_search
POST /management/v1/users/machine
PUT /management/v1/users/ID/secret" "$(calls | head -3)"
check "create body" '{"userName":"factory-slack-app","name":"factory-slack-app","accessTokenType":"ACCESS_TOKEN_TYPE_JWT"}' \
    "$(grep '^POST /management/v1/users/machine' "$T/api" | head -1 | cut -d' ' -f3- | jq -c '{userName,name,accessTokenType}')"
check "search is an exact userName query" factory-slack-app "$(grep '_search' "$T/api" | head -1 | cut -d' ' -f3- | jq -r '.queries[0].userNameQuery.userName')"
check "store key" "$KEY" "$(cat "$T/key" 2>/dev/null)"
check "payload" '{"client-id":"factory-slack-app","client-secret":"NEWSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
check "prints no secret" 0 "$(grep -c NEWSECRET <<<"$out")"
check "mirrored key recorded" "$KEY" "${mirrored_keys[*]:-}"

USERS='{"result":[{"userId":"u-1","userName":"factory-slack-app"}]}'
OKSTORE='{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}'  # pragma: allowlist secret
STORED="$OKSTORE"

echo "== 2. user exists, secret accepted, project id matches: nothing written, nothing rotated =="
run
check "exit 0" 0 "$rc"
check "calls: the search only" "POST /management/v1/users/_search" "$(calls | sort -u)"
check "nothing written" none "$(written)"
check "probed with the stored client id" factory-slack-app "$(cat "$T/probed-as")"
check "the mirror is retried and recorded" "$KEY" "${mirrored_keys[*]:-}"
MIRROR_RC=1; run
check "converged, mirror fails: nothing written, key in failed_mirrors" "none $KEY" "$(written) $failed_mirrors"
MIRROR_RC=0

echo "== 3. accepted secret, project id changed: rewritten, same secret =="
STORED='{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"old"}'  # pragma: allowlist secret
run
check "calls" "POST /management/v1/users/_search" "$(calls | sort -u)"
check "rewritten" '{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret

echo "== 3b. a stored client id ZITADEL no longer knows: the probe refuses it, one rotation stores the answered id =="
STORED='{"client-id":"stale","client-secret":"STOREDSECRET","project-id":"proj-1"}'  # pragma: allowlist secret
run
check "probed with the STORED id" stale "$(cat "$T/probed-as")"
check "rotated" "PUT /management/v1/users/ID/secret" "$(calls | grep PUT | sort -u)"
check "stored with the id ZITADEL answered" factory-slack-app "$(jq -r '."client-id"' "$T/written")"

echo "== 4. secret refused: rotate once, rewrite, restart nothing =="
STORED="$OKSTORE"; ACCEPT=1
run
check "calls" "POST /management/v1/users/_search
PUT /management/v1/users/ID/secret" "$(calls | head -2)"
check "rewritten with the new secret" '{"client-id":"factory-slack-app","client-secret":"NEWSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
check "no kubectl" 0 "$(grep -c kubectl "$T/api")"
check "prints no secret" 0 "$(grep -cE 'NEWSECRET|STOREDSECRET' <<<"$out")"

echo "== 4b. the answered client id is stored, even when it is not the user name; none answered: failure, nothing written =="
PUT_CLIENT_ID=cid-from-zitadel; run
check "stored with the answered id" cid-from-zitadel "$(jq -r '."client-id"' "$T/written")"
PUT_CLIENT_ID=""; run
check "no clientId answered: exit 1, nothing written" "1 none" "$rc $(written)"
PUT_CLIENT_ID=factory-slack-app

echo "== 4b2. a stored secret with no client id is invalid: rotated once, the answered id stored, never probed with an empty id =="
STORED='{"client-secret":"STOREDSECRET","project-id":"proj-1"}'; ACCEPT=0  # pragma: allowlist secret
run
check "rotated" "PUT /management/v1/users/ID/secret" "$(calls | grep PUT | sort -u)"
check "not probed" absent "$([ -e "$T/probed-as" ] && echo probed || echo absent)"
check "the answered client id stored" factory-slack-app "$(jq -r '."client-id"' "$T/written")"
STORED='{"client-id":"","client-secret":"STOREDSECRET","project-id":"proj-1"}'; run  # pragma: allowlist secret
check "empty client id: rotated, id stored" "PUT factory-slack-app" "$(calls | grep PUT | cut -d" " -f1 | sort -u) $(jq -r '."client-id"' "$T/written")"
STORED="$OKSTORE"

echo "== 4c. cannot tell: no rotation, but the project id converges and the mirror is retried =="
ACCEPT=2; STORED='{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"old"}'  # pragma: allowlist secret
run
check "no PUT" 0 "$(grep -c '^PUT' "$T/api")"
check "converged, same secret" '{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
STORED="$OKSTORE"; MIRROR_RC=1; run
check "cannot tell, converged, mirror fails: recorded" "$KEY" "$failed_mirrors"
MIRROR_RC=0; ACCEPT=0

echo "== 4d. no stored key: rotated and written =="
STORE_STATE=1; STORED='{}'
run
check "rotated" "PUT /management/v1/users/ID/secret" "$(calls | grep PUT | sort -u)"
check "written" "factory-slack-app" "$(jq -r '."client-id"' "$T/written")"

echo "== 4e. failures: an unreadable store mints nothing, a failed write or mirror is reported =="
STORE_STATE=2; run
check "unreadable store: exit 1, no PUT, no create, nothing written" "1 0 none" "$rc $(grep -cE '^(PUT|POST /management/v1/users/machine)' "$T/api") $(written)"
STORE_STATE=0; STORED="$OKSTORE"; ACCEPT=1; WRITE_RC=1; run
check "store write fails: exit 1" 1 "$rc"
WRITE_RC=2; run
check "mirror fails after a write: exit 0, key in failed_mirrors, not in mirrored_keys" "0 $KEY 0" "$rc $failed_mirrors ${#mirrored_keys[@]}"
WRITE_RC=0; ACCEPT=0

echo "== 5. APP_SUFFIX: the user is suffixed, the store key is not =="
APP_SUFFIX=-gcp-0; USERS='{"result":[]}'; PUT_CLIENT_ID=factory-slack-app-gcp-0
run
check "searched" factory-slack-app-gcp-0 "$(grep '_search' "$T/api" | head -1 | cut -d' ' -f3- | jq -r '.queries[0].userNameQuery.userName')"
check "created" factory-slack-app-gcp-0 "$(grep '/machine' "$T/api" | head -1 | cut -d' ' -f3- | jq -r .userName)"
check "store key unsuffixed" "$KEY" "$(cat "$T/key" 2>/dev/null)"
check "client-id carries the suffix" factory-slack-app-gcp-0 "$(jq -r '."client-id"' "$T/written")"
APP_SUFFIX=""; PUT_CLIENT_ID=factory-slack-app

echo "== 6. dry run: no mutating endpoint =="
APPLY=false; USERS='{"result":[]}'
run
check "missing user: reads only" "POST /management/v1/users/_search" "$(calls | sort -u)"
check "missing user: nothing written" none "$(written)"
USERS='{"result":[{"userId":"u-1","userName":"factory-slack-app"}]}'; ACCEPT=1
run
check "refused secret: reads only" "POST /management/v1/users/_search" "$(calls | sort -u)"
check "refused secret: nothing written" none "$(written)"
APPLY=true; ACCEPT=0

echo "== 7. declaration and map =="
check "MACHINE_USERS" "factory-slack-app|agents-factory-slack-principal" "${MACHINE_USERS[*]:-}"
check "bao-map" agents/factory-slack-principal "$(bao_target_for agents-factory-slack-principal 2>/dev/null)"

echo "== 8. cmd_sync calls it, and its failure does not cut the sync short =="
CLUSTER=c0; CLOUD=gcp; ZITADEL_PROJECT_NAME=platform; GRANT_ADMIN=""; GRANTS=(); CONSUMERS=()
ensure_project() { echo p1; }
ensure_project_role_assertion() { :; }
ensure_project_roles() { :; }
for f in reconcile_workforce_audience publish_project_id reconcile_openbao_oidc force_sync_mirrored; do
    eval "$f() { echo $f >>\"\$T/steps\"; }"
done
restart_rotated_consumers() { echo restart >>"$T/steps"; }
ensure_machine_user() { echo "ensure $1 $2" >>"$T/steps"; return "$EMU_RC"; }
run_sync() { rm -f "$T/steps"; out="$( ( set -o errexit -o nounset -o pipefail; cmd_sync ) 2>&1 )"; rc=$?; }
EMU_RC=0; run_sync
check "called with the declared user and key" "ensure factory-slack-app agents-factory-slack-principal" "$(grep '^ensure' "$T/steps")"
check "success: exit 0" 0 "$rc"
EMU_RC=1; run_sync
check "failure: exit 1" 1 "$rc"
check "failure: every later step still ran" "reconcile_workforce_audience publish_project_id reconcile_openbao_oidc force_sync_mirrored restart" \
    "$(grep -v '^ensure' "$T/steps" | tr '\n' ' ' | sed 's/ $//')"

echo "== 9. the real probe: what ZITADEL's answer means, and the secret off argv =="
unset -f probe_client_credentials; load_function probe_client_credentials "$SRC"
CURL_RESOLVE=(); CURL_RC=0 CURL_BODY="" CURL_CODE=200
curl() {
    printf '%s\n' "$@" >"$T/curl-argv"
    local out="" cfg=""
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -K) cfg="$2"; shift 2 ;; *) shift ;; esac; done
    cp "$cfg" "$T/curl-cfg"
    [ "$CURL_RC" -eq 0 ] || { echo "curl: (7) Failed to connect" >&2; return "$CURL_RC"; }
    printf '%s' "$CURL_BODY" >"$out"
    printf '%s' "$CURL_CODE"
}
probe() { rc=0; reason="$(printf '%s' "$1" | probe_client_credentials the-client 2>&1)" || rc=$?; }
CURL_CODE=200 CURL_BODY='{"access_token":"jwt","token_type":"Bearer"}'; probe 'we!rd"s\ecret'
check "200 with an access token: valid" 0 "$rc"
check "basic auth from the -K file, both halves form-encoded" 'user = "the-client:we%21rd%22s%5Cecret"' "$(cat "$T/curl-cfg")"
check "the secret is not on argv" no "$(grep -qF 'we!rd' "$T/curl-argv" && echo yes || echo no)"
check "a client-credentials grant" yes "$(grep -qx 'grant_type=client_credentials' "$T/curl-argv" && echo yes || echo no)"
CURL_CODE=400 CURL_BODY='{"error":"invalid_client","error_description":"invalid secret"}'; probe s
check "invalid_client: invalid" 1 "$rc"
CURL_CODE=400 CURL_BODY='{"error":"invalid_request","error_description":"x"}'; probe s
check "another error: cannot tell" 2 "$rc"
CURL_CODE=200 CURL_BODY='{}'; probe s
check "200 without a token: cannot tell" 2 "$rc"
CURL_CODE=500 CURL_BODY=''; probe s
check "no body: cannot tell" 2 "$rc"
CURL_RC=7; probe s
check "unreachable: cannot tell, with the reason" "2 yes" "$rc $(grep -q 'unreachable' <<<"$reason" && echo yes || echo no)"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
