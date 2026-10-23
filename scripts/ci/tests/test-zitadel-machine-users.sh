#!/usr/bin/env bash
# requires: bash jq
# shellcheck disable=SC2034,SC2218
# (the lifted function reads globals the harness defines; eval defines it before the calls)
#
# ensure_machine_user: the agent factory's Slack App is a ZITADEL machine user
# (client credentials, no project role). Functions are lifted verbatim with sed, like the
# sibling suites. Every API, store, mirror and kubectl path is a stub: no case reaches a cluster.
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
for f in ensure_machine_user stored_client_id stored_client_secret; do load_function "$f" "$SRC"; done
eval "$(sed -n '/^MACHINE_USERS=(/,/^)/p' "$SRC")"
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
IDP_URL=https://auth.example; APPLY=true; APP_SUFFIX=""; project_id=proj-1
mirrored_keys=(); failed_mirrors=""; rotated=()
KEY=agents-factory-slack-principal
STORED='{}'; STORE_EXISTS=1; USERS='{"result":[]}'; ACCEPT=0
# The calls the script makes; the new secret is a fixture, never a real credential.
api_or_fail() {
    printf '%s %s %s\n' "$1" "$2" "${4:-}" >>"$T/api"
    case "$1 $2" in
        "POST /management/v1/users/_search") printf '%s' "$USERS" ;;
        "POST /management/v1/users/machine") printf '{"userId":"u-new"}' ;;
        "PUT /management/v1/users/"*"/secret") jq -cn --arg id "factory-slack-app${APP_SUFFIX}" '{clientId: $id, clientSecret: "NEWSECRET"}' ;;  # pragma: allowlist secret
    esac
}
store_probe() { [ "$STORE_EXISTS" = 1 ]; }
store_exists() { store_probe "$1"; }
store_read() { printf '%s' "$STORED"; }
store_write_and_mirror() { printf '%s' "$1" >"$T/key"; cat >"$T/written"; }
mirror_to_openbao() { cat >/dev/null; }
probe_client_credentials() { cat >/dev/null; return "$ACCEPT"; }
kubectl() { echo "kubectl $*" >>"$T/api"; return 1; }
restart_rotated_consumers() { echo restart >>"$T/api"; }
run() { rm -f "$T/api" "$T/key" "$T/written"; : >"$T/api"; out="$(ensure_machine_user factory-slack-app "$KEY" 2>&1)"; rc=$?; }
calls() { cut -d' ' -f1,2 "$T/api" | sed 's#users/u-[a-z0-9]*#users/ID#'; }
written() { jq -c . "$T/written" 2>/dev/null || echo none; }

echo "== 1. no user: create it, generate its secret, store the three fields =="
run
check "exit 0" 0 "$rc"
check "calls" "POST /management/v1/users/_search
POST /management/v1/users/machine
PUT /management/v1/users/ID/secret" "$(calls)"
check "create body" '{"userName":"factory-slack-app","name":"factory-slack-app","accessTokenType":"ACCESS_TOKEN_TYPE_JWT"}' \
    "$(grep '^POST /management/v1/users/machine' "$T/api" | cut -d' ' -f3- | jq -cS . | jq -c '{userName,name,accessTokenType}')"
check "search is an exact userName query" factory-slack-app "$(grep '_search' "$T/api" | cut -d' ' -f3- | jq -r '.queries[0].userNameQuery.userName')"
check "store key" "$KEY" "$(cat "$T/key" 2>/dev/null)"
check "payload" '{"client-id":"factory-slack-app","client-secret":"NEWSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
check "prints no secret" 0 "$(grep -c NEWSECRET <<<"$out")"
check "restarts nothing" "0" "${#rotated[@]}"

USERS='{"result":[{"userId":"u-1","userName":"factory-slack-app"}]}'
OKSTORE='{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}'  # pragma: allowlist secret
STORED="$OKSTORE"

echo "== 2. user exists, secret accepted, ids match: nothing written, nothing rotated =="
run
check "exit 0" 0 "$rc"
check "calls: the search only" "POST /management/v1/users/_search" "$(calls)"
check "nothing written" none "$(written)"

echo "== 3. accepted secret, project-id or client-id changed: rewritten, same secret =="
STORED='{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"old"}'  # pragma: allowlist secret
run
check "project-id: calls" "POST /management/v1/users/_search" "$(calls)"
check "project-id: rewritten" '{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
STORED='{"client-id":"stale","client-secret":"STOREDSECRET","project-id":"proj-1"}'  # pragma: allowlist secret
run
check "client-id: rewritten" '{"client-id":"factory-slack-app","client-secret":"STOREDSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
check "client-id: no rotation" "POST /management/v1/users/_search" "$(calls)"

echo "== 4. secret refused: rotate once, rewrite, restart nothing =="
STORED="$OKSTORE"; ACCEPT=1
run
check "calls" "POST /management/v1/users/_search
PUT /management/v1/users/ID/secret" "$(calls)"
check "rewritten with the new secret" '{"client-id":"factory-slack-app","client-secret":"NEWSECRET","project-id":"proj-1"}' "$(written)"  # pragma: allowlist secret
check "no restart, no kubectl" 0 "$(grep -cE 'restart|kubectl' "$T/api")"
check "restart list empty" 0 "${#rotated[@]}"
check "prints no secret" 0 "$(grep -cE 'NEWSECRET|STOREDSECRET' <<<"$out")"
ACCEPT=2
run
check "cannot tell: not rotated" "POST /management/v1/users/_search" "$(calls)"
check "cannot tell: nothing written" none "$(written)"
ACCEPT=0
STORE_EXISTS=0; STORED='{}'
run
check "no stored key: rotated, written" "POST /management/v1/users/_search
PUT /management/v1/users/ID/secret" "$(calls)"
STORE_EXISTS=1

echo "== 5. APP_SUFFIX: the user is suffixed, the store key is not =="
APP_SUFFIX=-gcp-0; USERS='{"result":[]}'
run
check "searched" factory-slack-app-gcp-0 "$(grep '_search' "$T/api" | cut -d' ' -f3- | jq -r '.queries[0].userNameQuery.userName')"
check "created" factory-slack-app-gcp-0 "$(grep '/machine' "$T/api" | cut -d' ' -f3- | jq -r .userName)"
check "store key unsuffixed" "$KEY" "$(cat "$T/key" 2>/dev/null)"
check "client-id carries the suffix" factory-slack-app-gcp-0 "$(jq -r '."client-id"' "$T/written")"
APP_SUFFIX=""

echo "== 6. dry run: no mutating endpoint =="
APPLY=false; USERS='{"result":[]}'
run
check "missing user: reads only" "POST /management/v1/users/_search" "$(calls)"
check "missing user: nothing written" none "$(written)"
USERS='{"result":[{"userId":"u-1","userName":"factory-slack-app"}]}'; ACCEPT=1
run
check "refused secret: reads only" "POST /management/v1/users/_search" "$(calls)"
check "refused secret: nothing written" none "$(written)"
APPLY=true; ACCEPT=0

echo "== 7. declaration and map =="
check "MACHINE_USERS" "factory-slack-app|agents-factory-slack-principal" "${MACHINE_USERS[*]:-}"
check "bao-map" agents/factory-slack-principal "$(bao_target_for agents-factory-slack-principal 2>/dev/null)"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
