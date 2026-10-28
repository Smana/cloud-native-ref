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
check "the first owner, pinned to identities nobody else can claim" '{"loginName":"smaine.kahlouch@ogenki.io","githubLogin":"Smana","githubId":"4101366","googleSubject":"114494807855983228762","roles":["admin","agents-admin","agents-member"]}' "$(jq -c '.[0]' <<<"$real")"
own() { printf 'owners:\n  - {loginName: a@x, githubLogin: bob, githubId: "%s", googleSubject: "%s", roles: %s}\n' "$1" "$2" "$3" > "$T/o.yaml"; owners_json "$T/o.yaml" >"$T/o.out" 2>&1; }
own 1 2 '[admin]'; check "a complete entry is accepted" 0 "$?"
own 1 2 '[admin, admin, data]'; check "roles are de-duplicated" '["admin","data"]' "$(jq -c '.[0].roles' "$T/o.out")"
own x 2 '[admin]'; check "a non-numeric githubId is refused" 1 "$?"
own 1 'x' '[admin]'; check "a non-numeric googleSubject is refused" 1 "$?"
printf 'owners:\n  - {loginName: a@x, githubLogin: bob, githubId: "1", roles: [admin]}\n' > "$T/o.yaml"
owners_json "$T/o.yaml" >/dev/null 2>&1; check "an entry without googleSubject is refused" 1 "$?"
printf 'owners:\n  - {loginName: a@x, githubLogin: "../orgs", githubId: "1", googleSubject: "2", roles: [admin]}\n' > "$T/o.yaml"
owners_json "$T/o.yaml" >/dev/null 2>&1; check "a malformed GitHub login is refused" 1 "$?"
printf 'owners:\n  - {githubLogin: bob, githubId: "1", googleSubject: "2", roles: [admin]}\n' > "$T/o.yaml"
owners_json "$T/o.yaml" >/dev/null 2>&1; check "an entry without a loginName is refused" 1 "$?"
owners_json "$T/absent.yaml" >/dev/null 2>&1; check "an unreadable file: rc 2 (cannot parse), not 1 (invalid)" 2 "$?"
mkdir -p "$T/jqonly"; ln -sf "$(command -v jq)" "$T/jqonly/jq"
o="$(env PATH="$T/jqonly" "$BASH" -c ". '$OWNERS_LIB'; owners_json '$OWNERS_REAL'" 2>&1)"; r=$?
check "no parser: rc 2, naming what is needed" "2 yes" "$r $(grep -q 'PyYAML' <<<"$o" && echo yes || echo no)"

echo "== 2. load_owners: a problem with the list never stops the client sync =="
load_function load_owners "$SRC"
eval "$(grep -E '^ZITADEL_PROJECT_ROLES=\(' "$SRC")"
OWNERS_BAD=0
OWNERS_FILE="$OWNERS_REAL"; load_owners >/dev/null 2>&1
check "a good list is kept" "0 $OWNERS_REAL" "$? ${OWNERS_FILE}"
printf 'owners:\n  - {loginName: a@x, githubLogin: bob, githubId: "1", googleSubject: "2", roles: [root]}\n' > "$T/bad-role.yaml"
OWNERS_FILE="$T/bad-role.yaml"; o="$(load_owners 2>&1)"; load_owners >/dev/null 2>&1; r=$?
check "an unknown role: warns naming it, owners step off, no exit" "0 yes yes" "$r $(grep -q "root" <<<"$o" && echo yes || echo no) $([ -z "$OWNERS_FILE" ] && echo yes || echo no)"
check "an unknown role: the sync is told to fail at its end" 1 "$OWNERS_BAD"
OWNERS_BAD=0; OWNERS_FILE="$T/absent.yaml"; load_owners >/dev/null 2>&1; r=$?
check "a missing file: continues too" "0 1" "$r $OWNERS_BAD"
OWNERS_BAD=0; OWNERS_FILE="$OWNERS_REAL"
o="$(env PATH="$T/jqonly:/usr/bin/../bin" "$BASH" -c "$(declare -f load_owners); . '$OWNERS_LIB'; OWNERS_FILE='$OWNERS_REAL'; OWNERS_BAD=0; $(grep -E '^ZITADEL_PROJECT_ROLES=\(' "$SRC"); PATH='$T/jqonly'; load_owners; echo rc=\$? bad=\$OWNERS_BAD" 2>&1)"
check "no parser: warns, continues (rc 0), flags the failure" "yes" "$(grep -q 'rc=0 bad=1' <<<"$o" && grep -q PyYAML <<<"$o" && echo yes || echo no)"
OWNERS_FILE=""; OWNERS_BAD=0
mkdir -p "$T/bin"
for cli in curl gcloud aws kubectl bao; do
    printf '#!/usr/bin/env bash\necho %s >> "%s/cli-calls"\nexit 1\n' "$cli" "$T" > "$T/bin/$cli"
    chmod +x "$T/bin/$cli"
done

echo "== 3. grants of the list: to the user holding the Google subject, by nothing else =="
for f in grant_role grant_user_role search_all apply_owner_grants; do load_function "$f" "$SRC"; done
APPLY=true
cat > "$T/owners.yaml" <<'Y'
owners:
  - {loginName: alice@x, githubLogin: alice, githubId: "11", googleSubject: "1001", roles: [admin, agents-member]}
  - {loginName: ghost@x, githubLogin: ghost, githubId: "12", googleSubject: "1002", roles: [agents-admin]}
  - {loginName: dup@x, githubLogin: dup, githubId: "13", googleSubject: "1003", roles: [data]}
Y
OWNERS_FILE="$T/owners.yaml"; OWNERS_JSON="$(owners_json "$OWNERS_FILE")"
IDPS='{"result":[{"id":"idp-g","name":"Google Workspace","type":"PROVIDER_TYPE_GOOGLE"},{"id":"idp-gh","name":"GitHub","type":"PROVIDER_TYPE_GITHUB"}]}'
USERS_MODE=full
# u-squat registered alice@x as a local user, listed first and with no Google link.
api_or_fail() {
    case "$2" in
        */users/grants/_search) echo '{"result":[]}' ;;
        *) echo "name matching used: $2" >> "$T/name-matching"; echo '{"result":[]}' ;;
    esac
}
api() {
    local body="${4:-}"; [ "$body" = "@-" ] && body="$(cat)"
    printf '%s %s %s\n' "$1" "$2" "$(jq -c . <<< "${body:-null}")" >> "$T/api"
    case "$1 $2" in
        "GET /management/v1/orgs/me") echo '{"org":{"id":"org-1"}}' ;;
        "POST /admin/v1/idps/templates/_search") echo "$IDPS" ;;
        "POST /v2/users")
            echo "$body" >> "$T/users-req"
            case "$USERS_MODE" in
                paged) # two rows per page, three users, the owner on the second page
                    case "$(jq -r .query.offset <<< "$body")" in
                        0) echo '{"details":{"totalResult":"3"},"result":[{"userId":"u-squat"},{"userId":"u-d1"}]}' ;;
                        *) echo '{"details":{"totalResult":"3"},"result":[{"userId":"u-alice"}]}' ;;
                    esac ;;
                short) if [ "$(jq -r .query.offset <<< "$body")" = 0 ]; then echo '{"details":{"totalResult":"3"},"result":[{"userId":"u-squat"},{"userId":"u-alice"}]}'; else echo '{"details":{"totalResult":"3"},"result":[]}'; fi ;;
                *) # u-other is in ANOTHER org and holds a link with ghost's subject (a server ignoring the org filter)
                   echo '{"details":{"totalResult":"5"},"result":[{"userId":"u-squat"},{"userId":"u-alice"},{"userId":"u-d1"},{"userId":"u-d2"},{"userId":"u-other","details":{"resourceOwner":"org-2"}}]}' ;;
            esac ;;
        "POST /v2/users/u-alice/links/_search") echo '{"result":[{"idpId":"idp-g","userId":"1001"},{"idpId":"idp-gh","userId":"1003"}]}' ;;
        "POST /v2/users/u-d1/links/_search"|"POST /v2/users/u-d2/links/_search") echo '{"result":[{"idpId":"idp-g","userId":"1003"}]}' ;;
        "POST /v2/users/u-other/links/_search") echo '{"result":[{"idpId":"idp-g","userId":"1002"}]}' ;;
        "POST /v2/users/"*"/links/_search") echo '{"result":[]}' ;;
    esac
}
: > "$T/api"; rm -f "$T/name-matching" "$T/users-req"
o="$(apply_owner_grants p1 2>&1)"; r=$?
check "an unknown user and a duplicate: the list fails (the duplicate), after trying all" 1 "$r"
: > "$T/api"; apply_owner_grants p1 >/dev/null 2>&1
check "each role goes to the user holding the subject, not to the squatter" "POST /management/v1/users/u-alice/grants {\"projectId\":\"p1\",\"roleKeys\":[\"admin\"]}
POST /management/v1/users/u-alice/grants {\"projectId\":\"p1\",\"roleKeys\":[\"agents-member\"]}" "$(grep '/grants' "$T/api")"
check "nothing is written for anyone else" 2 "$(grep -c '^POST /management/v1/users/.*/grants ' "$T/api")"
check "no userName or email search is made" none "$([ -e "$T/name-matching" ] && echo used || echo none)"
check "no user: skipped with a clear message" 1 "$(grep -c '^\[skip   \] ghost@x: .*first login' <<<"$o")"
check "two users on one subject: refused loudly, nothing granted" "1 0" "$(grep -c '^\[FAILED \].*dup@x.*2 users\|^\[FAILED \].*dup@x.*several' <<<"$o") $(grep -c 'u-d[12]/grants' "$T/api")"
check "a user of another org holding ghost's subject: not granted" 0 "$(grep -c 'u-other/grants' "$T/api")"
check "ghost stays skipped although another org's user carries the subject" 1 "$(grep -c '^\[skip   \] ghost@x' <<<"$o")"
check "the user search is scoped to the project's org, sorted" "org-1 USER_FIELD_NAME_CREATION_DATE" "$(head -1 "$T/users-req" | jq -r '[.queries[0].organizationIdQuery.organizationId, .sortingColumn] | join(" ")')"
# paging until the total: the owner is on page 2
USERS_MODE=paged OWNERS_PAGE_SIZE=2; : > "$T/api"
apply_owner_grants p1 >/dev/null 2>&1
check "paged to the total: the owner on page 2 is found and granted" 2 "$(grep -c 'u-alice/grants' "$T/api")"
# a listing that returns fewer users than its total is an error, never a quiet success
USERS_MODE=short OWNERS_PAGE_SIZE=100; : > "$T/api"
o="$(apply_owner_grants p1 2>&1)"
check "fewer users than the total: not scanned, fails loudly, grants nothing" "yes 0" "$(grep -q 'not scanned' <<<"$o" && echo yes || echo no) $(grep -c '/grants ' "$T/api")"
USERS_MODE=full; unset OWNERS_PAGE_SIZE
# two instance IdPs with the same name: refused, nothing granted
IDPS='{"result":[{"id":"idp-g","name":"Google Workspace","type":"PROVIDER_TYPE_GOOGLE"},{"id":"idp-g2","name":"Google Workspace","type":"PROVIDER_TYPE_GOOGLE"}]}'
: > "$T/api"; o="$(apply_owner_grants p1 2>&1)"; r=$?
check "several IdPs by that name: refused, nothing granted" "1 0 1" "$r $(grep -c '/grants ' "$T/api") $(grep -c 'several ZITADEL IdPs' <<<"$o")"
# a same-named IdP of another type is not the Google IdP
IDPS='{"result":[{"id":"idp-x","name":"Google Workspace","type":"PROVIDER_TYPE_OIDC"},{"id":"idp-g","name":"Google Workspace","type":"PROVIDER_TYPE_GOOGLE"},{"id":"idp-gh","name":"GitHub","type":"PROVIDER_TYPE_GITHUB"}]}'
: > "$T/api"; apply_owner_grants p1 >/dev/null 2>&1
check "picked by type: the Google one, not the OIDC namesake" 2 "$(grep -c 'u-alice/grants' "$T/api")"
IDPS='{"result":[{"id":"idp-g","name":"Google Workspace","type":"PROVIDER_TYPE_GOOGLE"},{"id":"idp-gh","name":"GitHub","type":"PROVIDER_TYPE_GITHUB"}]}'
# The explicit --grant stays the owner's interactive tool: name matching, a missing user fails.
api_or_fail() {
    case "$2" in
        */users/_search) echo '{"result":[{"id":"u-alice","userName":"alice@x"}]}' ;;
        */users/grants/_search) echo '{"result":[]}' ;;
    esac
}
grant_role agents-admin ghost@x p1 >/dev/null 2>&1
check "an explicit --grant of a missing user still fails" 1 "$?"
api_or_fail() {
    case "$2" in
        */users/_search) echo '{"result":[{"id":"u-a","userName":"dup@x"},{"id":"u-b","human":{"email":{"email":"dup@x"}}}]}' ;;
        */users/grants/_search) echo '{"result":[]}' ;;
    esac
}
: > "$T/api"; o="$(grant_role agents-admin dup@x p1 2>&1)"; r=$?
check "an explicit --grant matching two users is refused, nothing written" "1 0 1" "$r $(grep -c '/grants ' "$T/api") $(grep -c 'several ZITADEL users' <<<"$o")"
api() { [ "${4:-}" != "@-" ] || cat >/dev/null; case "$2" in */grants) return 22 ;; "/admin/v1/idps/templates/_search") echo '{"result":[{"id":"idp-g","name":"Google Workspace"}]}' ;; "/v2/users") echo '{"result":[{"userId":"u-alice"}]}' ;; */links/_search) echo '{"result":[{"idpId":"idp-g","userId":"1001"}]}' ;; esac; }
printf 'owners:\n  - {loginName: alice@x, githubLogin: alice, githubId: "11", googleSubject: "1001", roles: [admin]}\n' > "$T/one.yaml"
OWNERS_FILE="$T/one.yaml"; OWNERS_JSON="$(owners_json "$OWNERS_FILE")"
api_or_fail() { echo '{"result":[]}'; }
apply_owner_grants p1 >/dev/null 2>&1
check "a refused write fails the list" 1 "$?"
api() { case "$2" in "/admin/v1/idps/templates/_search") return 22 ;; esac; }
o="$(apply_owner_grants p1 2>&1)"; r=$?
check "an API failure on the IdP lookup is an error, not a skip" "1 0" "$r $(grep -c '^\[skip' <<<"$o")"
unset -f api api_or_fail

echo "== 4. ensure_machine_user: a 409 on create means the user exists =="
for f in machine_user_id write_public ensure_machine_user stored_client_id stored_client_secret probe_client_credentials; do load_function "$f" "$SRC"; done
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
            echo '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"OAUTH2_PROXY_CLIENT_ID","valueFrom":{"secretKeyRef":{"name":"rooms-proxy","key":"client-id"}}},{"name":"OAUTH2_PROXY_EXTRA_OIDC_ISSUERS","valueFrom":{"secretKeyRef":{"name":"rooms-proxy-extra-issuers","key":"issuers"}}}]}]}}}}' ;;
        # rooms-proxy-extra-issuers holds <issuer>=<roomctl client id>, never the proxy's own id
        "get secret") if [[ "$*" == *rooms-proxy-extra-issuers* ]]; then jq -n --arg v "$(printf '%s' "https://auth.example=roomctl-id" | base64)" '{data:{issuers:$v}}'
                      else jq -n --arg v "$(printf '%s' "$SECRET_ID" | base64)" '{data:{"client-id":$v}}'; fi ;;
    esac
}
restarts() { grep -c '^rollout restart deployment rooms-oauth2-proxy -n agent-system' "$T/kc" || true; }
: > "$T/kc"; restart_rooms_proxy new-id >"$T/out" 2>&1
check "restarts deploy/rooms-oauth2-proxy in agent-system" 1 "$(restarts)"
: > "$T/kc"; DEPLOY=absent restart_rooms_proxy new-id >"$T/out" 2>&1
check "no Deployment yet: skipped, no restart" 0 "$(restarts)"
DEPLOY=absent restart_rooms_proxy new-id >/dev/null 2>&1
check "no Deployment yet: exit 0" 0 "$?"
: > "$T/kc"; SECRET_ID=old-id restart_rooms_proxy new-id >"$T/out" 2>&1
check "Secret still on the old client: no restart onto it" 0 "$(restarts)"
check "Secret still on the old client: says so, naming rooms-proxy" 1 "$(grep -c 'agent-system/rooms-proxy does not carry client new-id' "$T/out")"
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

# restart_rotated_consumers already rolled the proxy when its key was rotated: no second restart.
app_id_by_name() { echo ""; }
previous_client_id() { echo OLD; }
run_cmd_sync
check "key rotated (restart_rotated_consumers' job): no second restart" "0 " "$rc $(proxy_calls)"
restart_rotated_consumers() { :; }
unset -f previous_client_id; load_function previous_client_id "$SRC"

echo "== 7. cmd_sync applies the list =="
grant_role() { printf '%s %s %s\n' "$1" "$2" "$3" >>"$T/grants"; }
apply_owner_grants() { echo "owners $1" >>"$T/grants"; }
OWNERS_FILE="$T/owners.yaml"; : > "$T/grants"; app_id_by_name() { echo app-1; }
run_cmd_sync
check "cmd_sync applies the owners' grants with the project id" "owners p1" "$(cat "$T/grants")"
apply_owner_grants() { return 1; }
run_cmd_sync
check "a failed list does not stop the sync (summary printed) and fails it" "1 1" "$rc $(grep -c '^created:' <<<"$out")"

echo "== 8. the workflow warnings name the step that failed =="
for wf in opentofu/gcp/gke/init/workflows.tm.hcl opentofu/aws/eks/init/workflows.tm.hcl; do
    check "$wf: the client sync warning names clients, mirrors and the owners' grants" 1 \
        "$(grep -c "client sync reported a failure.*machine users or the owners list's grants" "$REPO_ROOT/$wf")"
    check "$wf: the owners link step names itself" 1 "$(grep -c "linking the owners' GitHub accounts failed" "$REPO_ROOT/$wf")"
done
check "gcp: no bare 'OIDC registration failed' left on the hosting path" 0 "$(grep -c '\[warn\] OIDC registration failed; re-run it by hand' "$REPO_ROOT/opentofu/gcp/gke/init/workflows.tm.hcl")"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
