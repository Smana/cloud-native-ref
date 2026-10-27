#!/usr/bin/env bash
# requires: bash jq
# shellcheck disable=SC2034,SC2218,SC2329
# (the lifted functions read globals the harness defines; eval defines them before the calls)
#
# Developer onboarding on a rebuild (O1, O2) in zitadel-oidc-clients.sh: the owners
# list in git whose grants every sync applies, the rooms-proxy client change that
# restarts oauth2-proxy, and a machine user ZITADEL already has. The GitHub links
# of the same list are in test-zitadel-idp-convergence.sh (link-owners).
# Functions are lifted verbatim with sed, like the sibling suites; every API,
# store and kubectl path is a stub, no case reaches a cluster.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../provision/zitadel-oidc-clients.sh}"
OWNERS_LIB="$REPO_ROOT/scripts/lib/zitadel-owners.sh"
OWNERS_REAL="$REPO_ROOT/scripts/provision/zitadel-owners.yaml"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
load_function() {
    local body
    body="$(sed -n "/^${1}() {/,/^}/p" "$2")"
    [ -n "$body" ] || body="$(sed -n "/^${1}() (/,/^)/p" "$2")"
    [ -n "$body" ] || { echo "could not extract ${1}() from $2" >&2; exit 1; }
    eval "$body"
}
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

echo "== 1. the owners list in git =="
# shellcheck source=scripts/lib/zitadel-owners.sh
. "$OWNERS_LIB" 2>/dev/null || { echo "  FAIL cannot source $OWNERS_LIB"; exit 1; }
real="$(owners_json "$OWNERS_REAL" 2>&1)"
check "the first owner" '{"loginName":"smaine.kahlouch@ogenki.io","githubLogin":"Smana","roles":["admin","agents-admin","agents-member"]}' "$(jq -c '.[0]' <<<"$real")"
cat > "$T/bad-gh.yaml" <<'Y'
owners:
  - {loginName: a@x, githubLogin: "../orgs", roles: [admin]}
Y
owners_json "$T/bad-gh.yaml" >/dev/null 2>&1
check "a malformed GitHub login is refused" 1 "$?"
cat > "$T/no-login.yaml" <<'Y'
owners:
  - {githubLogin: bob, roles: [admin]}
Y
owners_json "$T/no-login.yaml" >/dev/null 2>&1
check "an entry without a loginName is refused" 1 "$?"
owners_json "$T/absent.yaml" >/dev/null 2>&1
check "an unreadable file is refused" 1 "$?"

echo "== 2. --owners is validated before any call =="
mkdir -p "$T/bin"
for cli in curl gcloud aws kubectl bao; do
    printf '#!/usr/bin/env bash\necho %s >> "%s/cli-calls"\nexit 1\n' "$cli" "$T" > "$T/bin/$cli"
    chmod +x "$T/bin/$cli"
done
cat > "$T/bad-role.yaml" <<'Y'
owners:
  - {loginName: a@x, githubLogin: bob, roles: [root]}
Y
o="$(PATH="$T/bin:$PATH" timeout 10 bash "$SRC" sync --cluster c0 --cloud gcp --owners "$T/bad-role.yaml" 2>&1)"; r=$?
check "an unknown role: exit 2, no CLI called" "2 none" "$r $([ -e "$T/cli-calls" ] && echo called || echo none)"
grep -q "root" <<<"$o" || { echo "  FAIL the refusal does not name the role: $(head -2 <<<"$o")"; fail=1; }
o="$(PATH="$T/bin:$PATH" timeout 10 bash "$SRC" sync --cluster c0 --cloud gcp --owners "$T/absent.yaml" 2>&1)"; r=$?
check "a missing file: exit 2, no CLI called" "2 none" "$r $([ -e "$T/cli-calls" ] && echo called || echo none)"

echo "== 3. grants of the list: applied, an unknown user skipped =="
for f in grant_role search_all apply_owner_grants; do load_function "$f" "$SRC"; done
eval "$(grep -E '^ZITADEL_PROJECT_ROLES=\(' "$SRC")"
APPLY=true
cat > "$T/owners.yaml" <<'Y'
owners:
  - {loginName: alice@x, githubLogin: alice, roles: [admin, agents-member]}
  - {loginName: ghost@x, githubLogin: ghost, roles: [agents-admin]}
Y
api_or_fail() {
    case "$2" in
        */users/_search) echo '{"result":[{"id":"u-alice","userName":"alice@x"}]}' ;;
        */users/grants/_search) echo '{"result":[]}' ;;
    esac
}
api() { printf '%s %s %s\n' "$1" "$2" "$(jq -c .)" >> "$T/api"; }
: > "$T/api"; OWNERS_FILE="$T/owners.yaml"
o="$(apply_owner_grants p1 2>&1)"; r=$?
check "the list: exit 0 with an unknown user in it" 0 "$r"
apply_owner_grants p1 >/dev/null 2>&1
check "each role of a known user is granted" "POST /management/v1/users/u-alice/grants {\"projectId\":\"p1\",\"roleKeys\":[\"admin\"]}
POST /management/v1/users/u-alice/grants {\"projectId\":\"p1\",\"roleKeys\":[\"agents-member\"]}" "$(head -2 "$T/api")"
check "the unknown user: skipped with a clear message" 1 "$(grep -c '^\[skip   \] ghost@x .*first login' <<<"$o")"
check "the unknown user: no write for them" 0 "$(grep -c 'agents-admin' "$T/api")"
check "the unknown user: not a failure line" 0 "$(grep -c '^\[FAILED' <<<"$o")"
# --grant of a missing user stays a failure: the owner typed that one.
GRANT_MISSING_OK=false grant_role agents-admin ghost@x p1 >/dev/null 2>&1
check "an explicit --grant of a missing user still fails" 1 "$?"
api() { cat >/dev/null; return 22; }
apply_owner_grants p1 >/dev/null 2>&1
check "a refused write fails the list" 1 "$?"
unset -f api api_or_fail

echo "== 4. ensure_machine_user: a 409 on create means the user exists =="
for f in machine_user_id ensure_machine_user stored_client_id stored_client_secret probe_client_credentials; do load_function "$f" "$SRC"; done
project_id=proj-1; APP_SUFFIX=""; mirrored_keys=(); failed_mirrors=""
SEARCHES=0
api_or_fail() {
    printf '%s %s\n' "$1" "$2" >>"$T/m409"
    case "$1 $2" in
        "POST /management/v1/users/_search")
            echo x >>"$T/searches"; SEARCHES="$(wc -l < "$T/searches")"
            # the first search misses the user (the race), the one after the 409 finds it
            if [ "$SEARCHES" -ge "$FIND_AFTER" ]; then echo '{"result":[{"id":"u-9","userName":"factory-slack-app"}]}'; else echo '{"result":[]}'; fi ;;
        "POST /management/v1/users/machine")
            echo "[FAILED ] ZITADEL API call failed: POST /management/v1/users/machine" >&2
            echo "           curl: (22) The requested URL returned error: ${CREATE_CODE}" >&2
            return 1 ;;
        "PUT /management/v1/users/u-9/secret") echo '{"clientId":"factory-slack-app","clientSecret":"NEWSECRET"}' ;;  # pragma: allowlist secret
    esac
}
store_probe() { return 1; }
store_write_and_mirror() { cat >"$T/m409-written"; }
mirror_to_openbao() { cat >/dev/null; }
rm -f "$T/searches"; : > "$T/m409"; rm -f "$T/m409-written"; SEARCHES=0 FIND_AFTER=2 CREATE_CODE=409
o="$(ensure_machine_user factory-slack-app agents-factory-slack-principal 2>&1)"; r=$?
check "409: converges, exit 0" 0 "$r"
check "409: the secret is generated for the existing user" 1 "$(grep -c '^PUT /management/v1/users/u-9/secret' "$T/m409")"
check "409: stored" factory-slack-app "$(jq -r '."client-id"' "$T/m409-written" 2>/dev/null)"
check "409: no failure line" 0 "$(grep -c '^\[FAILED' <<<"$o")"
: > "$T/searches"; : > "$T/m409"; SEARCHES=0 FIND_AFTER=99 CREATE_CODE=409
o="$(ensure_machine_user factory-slack-app agents-factory-slack-principal 2>&1)"; r=$?
check "409 and still not found: fails, names the user" "1 yes" "$r $(grep -q 'factory-slack-app' <<<"$o" && echo yes || echo no)"
: > "$T/searches"; : > "$T/m409"; SEARCHES=0 FIND_AFTER=99 CREATE_CODE=500
o="$(ensure_machine_user factory-slack-app agents-factory-slack-principal 2>&1)"; r=$?
check "a 500 on create still fails, and says so" "1 yes" "$r $(grep -q 'error: 500' <<<"$o" && echo yes || echo no)"
# The v1 search answers `id`; the lifted tests of older suites fed `userId`. Both are read.
api_or_fail() { printf '%s %s\n' "$1" "$2" >>"$T/m409"; case "$2" in */users/_search) echo '{"result":[{"id":"u-9","userName":"factory-slack-app"}]}' ;; esac; }
store_probe() { return 0; }; store_read() { echo '{"client-id":"factory-slack-app","client-secret":"S","project-id":"proj-1"}'; }  # pragma: allowlist secret
probe_client_credentials() { cat >/dev/null; }
: > "$T/m409"
ensure_machine_user factory-slack-app agents-factory-slack-principal >/dev/null 2>&1
check "an existing user answered with id is found: no create" 0 "$(grep -c 'users/machine' "$T/m409")"
unset -f api_or_fail

echo "== 5. restart_rooms_proxy: only with the Secret carrying the new client, only when the Deployment exists =="
for f in secret_carries secret_sha restart_rooms_proxy; do load_function "$f" "$SRC"; done
sleep() { :; }
CLUSTER=gcp-0 APPLY=true OIDC_CONSUMER_WAIT_SECONDS=0 CM=gke-gcp-0-vars SECRET_ID=new-id DEPLOY=present
kubectl() {
    printf '%s\n' "$*" >>"$T/kc"
    case "$1 $2" in
        "get configmap") printf 'configmap/%s\n' "$CM" ;;
        "get deployment") [ "$DEPLOY" = present ] || return 1
            echo '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"OAUTH2_PROXY_CLIENT_ID","valueFrom":{"secretKeyRef":{"name":"rooms-proxy","key":"client-id"}}}]}]}}}}' ;;
        "get secret") jq -n --arg v "$(printf '%s' "$SECRET_ID" | base64)" '{data:{"client-id":$v}}' ;;
    esac
}
restarts() { grep -c '^rollout restart deployment rooms-oauth2-proxy -n agent-system' "$T/kc" || true; }
: > "$T/kc"; restart_rooms_proxy new-id >"$T/out" 2>&1
check "restarts deploy/rooms-oauth2-proxy in agent-system" 1 "$(restarts)"
: > "$T/kc"; DEPLOY=absent restart_rooms_proxy new-id >"$T/out" 2>&1
check "no Deployment yet: skipped, no restart, exit 0" "0 0" "$(restarts) $?"
: > "$T/kc"; SECRET_ID=old-id restart_rooms_proxy new-id >"$T/out" 2>&1
check "Secret still on the old client: no restart onto it" 0 "$(restarts)"
check "Secret still on the old client: says so" 1 "$(grep -c 'does not carry client new-id' "$T/out")"
: > "$T/kc"; APPLY=false restart_rooms_proxy new-id >/dev/null 2>&1
check "dry run: no kubectl" 0 "$(wc -l < "$T/kc")"
: > "$T/kc"; CM=eks-aws-0-vars restart_rooms_proxy new-id >"$T/out" 2>&1
check "kubectl on another cluster: no restart" 0 "$(restarts)"
unset -f kubectl

echo "== 6. cmd_sync restarts the proxy on a client change only =="
for f in cmd_sync previous_client_id oidc_config_payload app_set_redirect merge_secret converge_secret; do load_function "$f" "$SRC"; done
PRIVATE_DOMAIN=priv.example; CLOUD=gcp; ZITADEL_PROJECT_NAME=platform; GRANT_ADMIN=""; GRANTS=(); OWNERS_FILE=""
IDP_URL=https://auth.example; HEADLAMP_OIDC_SCOPES=profile; MACHINE_USERS=(); MIRROR_OPENBAO=false
entry="$(grep -E '^[[:space:]]*"rooms-proxy\|' "$SRC" | head -1)"
eval "CONSUMERS=(${entry})"
ensure_project() { echo p1; }
ensure_project_role_assertion() { :; }; ensure_project_roles() { :; }
grant_role() { :; }
for f in reconcile_workforce_audience publish_project_id reconcile_openbao_oidc force_sync_mirrored ensure_machine_user restart_rotated_consumers; do eval "$f() { :; }"; done
restart_rooms_proxy() { echo "restart-proxy $1" >>"$T/proxy"; }
mirror_read() { :; }
store_probe() { return 0; }
rp='{"client-id":"CID","client-secret":"S","cookie-secret":"0123456789abcdef0123456789abcdef","project-id":"p1"}'  # pragma: allowlist secret
store_read() { printf '%s' "$rp"; }
store_write_and_mirror() { cat >/dev/null; }
probe_client_secret() { cat >/dev/null; }
api_or_fail() { printf '{"clientId":"NEW","clientSecret":"S"}'; }  # pragma: allowlist secret
api() { :; }
run_cmd_sync() { rm -f "$T/proxy"; out="$( ( set -o errexit -o nounset -o pipefail; cmd_sync; cat "$T/proxy" 2>/dev/null || true ) 2>&1 )"; rc=$?; }
proxy_calls() { grep '^restart-proxy' <<<"$out" || true; }
app_id_by_name() { echo ""; }
run_cmd_sync
check "client created: restart, with the new client id" "0 restart-proxy NEW" "$rc $(proxy_calls)"
app_id_by_name() { echo app-1; }
app_get() { jq -n '{app: {oidcConfig: {redirectUris: ["https://rooms.stale/oauth2/callback"], clientId: "CID", accessTokenType: "OIDC_TOKEN_TYPE_JWT"}}}'; }
run_cmd_sync
check "client changed (redirect repaired): restart" "0 restart-proxy CID" "$rc $(proxy_calls)"
app_get() { jq -n '{app: {oidcConfig: {redirectUris: ["https://rooms.priv.example/oauth2/callback"], clientId: "CID", accessTokenType: "OIDC_TOKEN_TYPE_JWT"}}}'; }
run_cmd_sync
check "client unchanged: no restart" "0 " "$rc $(proxy_calls)"
APPLY=false; run_cmd_sync; APPLY=true
check "dry run: no restart" "0 " "$rc $(proxy_calls)"
app_id_by_name() { echo ""; }; APPLY=false; run_cmd_sync; APPLY=true
check "dry run create: no restart" "0 " "$rc $(proxy_calls)"

echo "== 7. cmd_sync applies the list =="
grant_role() { printf '%s %s %s\n' "$1" "$2" "$3" >>"$T/grants"; }
apply_owner_grants() { echo "owners $1" >>"$T/grants"; }
OWNERS_FILE="$T/owners.yaml"; : > "$T/grants"; app_id_by_name() { echo app-1; }
run_cmd_sync
check "cmd_sync applies the owners' grants with the project id" "owners p1" "$(cat "$T/grants")"
apply_owner_grants() { return 1; }
run_cmd_sync
check "a failed list does not stop the sync (summary printed) and fails it" "1 1" "$rc $(grep -c '^created:' <<<"$out")"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
