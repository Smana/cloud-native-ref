#!/usr/bin/env bash
# shellcheck disable=SC2034
# (functions lifted from zitadel-oidc-clients.sh read these globals)
# requires: jq openssl
#
# The rooms-proxy consumer (SP2 ruling P12) and the agent groups. JWT access
# tokens that survive a redirect repair; a hyphenated oauth2-proxy payload that
# reaches OpenBao's agents mount through the existing mirror, not a second
# OpenBao writer (ruling AU); force-sync that finds agent-system's ExternalSecret;
# and --grant adding a role to an existing grant instead of failing on a second
# one. Functions are lifted verbatim with sed, like the sibling suites: a
# restatement would test the copy, not the script.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="${ZITADEL_OIDC_CLIENTS_SCRIPT:-$HERE/../../provision/zitadel-oidc-clients.sh}"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }
load_function() {
    local body
    body="$(sed -n "/^${1}() {/,/^}/p" "$2")"
    # mirror_to_openbao is a subshell function: `() (` ... `)`.
    [ -n "$body" ] || body="$(sed -n "/^${1}() (/,/^)/p" "$2")"
    [ -n "$body" ] || { echo "could not extract ${1}() from $2" >&2; exit 1; }
    eval "$body"
}
for f in oidc_config_payload app_set_redirect merge_secret converge_secret grant_role \
         mirror_to_openbao force_sync_mirrored cmd_sync; do
    load_function "$f" "$SRC"
done
# shellcheck source=scripts/lib/bao-map.sh
. "$REPO_ROOT/scripts/lib/bao-map.sh"
eval "$(sed -n '/^MIRRORED_FIELDS=(/,/^)/p' "$SRC")"
eval "$(grep -E '^ZITADEL_PROJECT_ROLES=\(' "$SRC")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
IDP_URL=https://auth.example; HEADLAMP_OIDC_SCOPES=profile; APPLY=true

echo "== 1. JWT access tokens, on create AND on the redirect repair =="
check "create: JWT" OIDC_TOKEN_TYPE_JWT "$(oidc_config_payload https://rooms.x/oauth2/callback rooms-proxy jwt | jq -r .accessTokenType)"
check "update: JWT kept" OIDC_TOKEN_TYPE_JWT "$(oidc_config_payload https://rooms.x/oauth2/callback '' jwt | jq -r .accessTokenType)"
check "others: bearer" OIDC_TOKEN_TYPE_BEARER "$(oidc_config_payload https://grafana.x/cb grafana | jq -r .accessTokenType)"
api() { printf '%s' "$4" > "$T/put"; }
app_set_redirect p1 a1 https://rooms.x/oauth2/callback jwt
check "repair PUT: JWT kept" OIDC_TOKEN_TYPE_JWT "$(jq -r .accessTokenType "$T/put")"
app_set_redirect p1 a1 https://grafana.x/cb
check "repair PUT: others bearer" OIDC_TOKEN_TYPE_BEARER "$(jq -r .accessTokenType "$T/put")"
unset -f api

echo "== 2. The oauth2-proxy payload: cookie secret exactly 32 characters, and preserved =="
store_exists() { return 1; }
store_read() { echo '{}'; }
p="$(merge_secret agents-rooms-proxy rooms-proxy CID SECRET)"
check "client-id" CID "$(jq -r '."client-id"' <<<"$p")"
check "client-secret" SECRET "$(jq -r '."client-secret"' <<<"$p")"
check "cookie length" 32 "$(jq -r '."cookie-secret" | length' <<<"$p")"
store_exists() { return 0; }
store_read() { echo '{"cookie-secret":"kept-cookie-fixture"}'; }  # pragma: allowlist secret
check "an existing cookie secret is kept" kept-cookie-fixture \
    "$(merge_secret agents-rooms-proxy rooms-proxy CID SECRET | jq -r '."cookie-secret"')"
check "converge keeps the secret" SECRET "$(converge_secret rooms-proxy CID2 "$p" | jq -r '."client-secret"')"
check "converge updates the id" CID2 "$(converge_secret rooms-proxy CID2 "$p" | jq -r '."client-id"')"
check "converge keeps the cookie" "$(jq -r '."cookie-secret"' <<<"$p")" "$(converge_secret rooms-proxy CID2 "$p" | jq -r '."cookie-secret"')"

echo "== 3. The mirror writes agents/data/rooms-proxy (the agents mount, P38; ruling AU) =="
check "bao-map: agents-rooms-proxy" agents/rooms-proxy "$(bao_target_for agents-rooms-proxy 2>/dev/null)"
openbao_token_config_write() { : >"$1"; }
openbao_req() {
    printf '%s %s\n' "$1" "$2" >>"$T/calls"
    local method="$1" out=/dev/null
    shift 2
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    case "$method" in
        GET)  printf '{"errors":[]}' >"$out"; printf 404 ;;
        POST) cat >"$T/body" ;;
    esac
}
MIRROR_OPENBAO=true; OPENBAO_ROOT_TOKEN_SECRET=fixture
printf '%s' "$p" | mirror_to_openbao agents-rooms-proxy >/dev/null 2>&1
check "mirror path" "POST agents/data/rooms-proxy" "$(grep '^POST' "$T/calls" 2>/dev/null)"
check "mirror body: the whole payload" "$(jq -cS . <<<"$p")" "$(jq -cS .data "$T/body" 2>/dev/null)"

echo "== 4. force-sync finds agent-system's ExternalSecret (store agents-secrets, not openbao-agents) =="
kubectl() {
    printf '%s\n' "$*" >>"$T/kubectl"
    case "$1" in
        get) printf '%s' '{"items":[
          {"metadata":{"namespace":"agent-system","name":"rooms-proxy"},"spec":{"secretStoreRef":{"name":"agents-secrets","kind":"SecretStore"},"dataFrom":[{"extract":{"key":"rooms-proxy"}}]}},
          {"metadata":{"namespace":"agent-system","name":"other"},"spec":{"secretStoreRef":{"name":"agents-secrets","kind":"SecretStore"},"dataFrom":[{"extract":{"key":"github-app"}}]}}]}' ;;
        annotate) return 0 ;;
    esac
}
force_sync_mirrored agents-rooms-proxy >/dev/null 2>&1
check "force-sync: exactly the rooms-proxy ExternalSecret" "agent-system/rooms-proxy" \
    "$(grep '^annotate' "$T/kubectl" 2>/dev/null | awk '{print $5"/"$3}')"
unset -f kubectl

echo "== 5. --grant: add the role to an existing grant (PUT), else a new grant (POST) =="
GRANTS_JSON='{"result":[{"id":"g1","userId":"u1","projectId":"p1","roleKeys":["backend"]}]}'
api_or_fail() {
    case "$2" in
        */users/_search) echo '{"result":[{"id":"u1","userName":"dev@x"}]}' ;;
        */users/grants/_search) echo "$GRANTS_JSON" ;;
    esac
}
api() { printf '%s %s %s\n' "$1" "$2" "$(jq -c .)" >> "$T/api"; }
: > "$T/api"
grant_role agents-member dev@x p1 >/dev/null
check "grant: PUT the union" "PUT /management/v1/users/u1/grants/g1" "$(cut -d' ' -f1,2 "$T/api")"
check "grant: roles" '["agents-member","backend"]' "$(cut -d' ' -f3- "$T/api" | jq -c '.roleKeys | sort')"
: > "$T/api"
grant_role backend dev@x p1 >/dev/null
check "grant: a held role is not written again" "" "$(cat "$T/api")"
: > "$T/api"
GRANTS_JSON='{"result":[{"id":"g9","userId":"u1","projectId":"OTHER","roleKeys":["admin"]}]}'
grant_role agents-admin dev@x p1 >/dev/null
check "grant: no grant on this project -> POST" "POST /management/v1/users/u1/grants" "$(cut -d' ' -f1,2 "$T/api")"
check "grant: POST body" '{"projectId":"p1","roleKeys":["agents-admin"]}' "$(cut -d' ' -f3- "$T/api" | jq -c .)"
: > "$T/api"
APPLY=false grant_role agents-admin dev@x p1 >/dev/null
check "grant: nothing on a dry run" "" "$(cat "$T/api")"
grant_role agents-admin nobody@x p1 >/dev/null 2>&1
check "grant: an unknown user fails" 1 "$?"
unset -f api api_or_fail

echo "== 6. The agent groups exist as project roles =="
check "agents-admin role" true "$(printf '%s\n' "${ZITADEL_PROJECT_ROLES[@]}" | grep -qx agents-admin && echo true || echo false)"
check "agents-member role" true "$(printf '%s\n' "${ZITADEL_PROJECT_ROLES[@]}" | grep -qx agents-member && echo true || echo false)"

echo "== 7. cmd_sync: the rooms-proxy entry, JWT on both paths, grants before the loop =="
PRIVATE_DOMAIN=priv.example; CLUSTER=c0; CLOUD=gcp; ZITADEL_PROJECT_NAME=platform; APP_SUFFIX=""
entry="$(grep -E '^[[:space:]]*"rooms-proxy\|' "$SRC" | head -1)"
eval "CONSUMERS=(${entry})"
check "entry: redirect|key|token" "https://rooms.priv.example/oauth2/callback|agents-rooms-proxy|jwt" "$(cut -d'|' -f2- <<<"${CONSUMERS[0]:-}")"
ensure_project() { echo p1; }
ensure_project_role_assertion() { :; }
ensure_project_roles() { :; }
grant_role() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$T/grants"; }
reconcile_workforce_audience() { :; }
publish_project_id() { :; }
reconcile_openbao_oidc() { :; }
force_sync_mirrored() { :; }
store_probe() { return 0; }
store_read() { printf '%s' "$p"; }
store_write_and_mirror() { cat > "$T/written-$1"; }
api_or_fail() { printf '%s' "$4" > "$T/create"; printf '{"clientId":"NEW","clientSecret":"S"}'; }  # pragma: allowlist secret
api() { printf '%s' "$4" > "$T/put"; }
run_cmd_sync() { out="$( ( set -o errexit -o nounset -o pipefail; cmd_sync ) 2>&1 )"; rc=$?; }

app_id_by_name() { echo ""; }
GRANT_ADMIN=a@x; GRANTS=("agents-member=dev@x")
: > "$T/grants"
run_cmd_sync
check "create: cmd_sync succeeds" 0 "$rc"
check "create: JWT" OIDC_TOKEN_TYPE_JWT "$(jq -r .accessTokenType "$T/create" 2>/dev/null)"
check "create: written to agents-rooms-proxy" NEW "$(jq -r '."client-id"' "$T/written-agents-rooms-proxy" 2>/dev/null)"
check "grants: both --grant-admin and --grant" "agents-member dev@x p1
admin a@x p1" "$(sort -r "$T/grants")"

grant_role() { return 1; }
rm -f "$T/create"
run_cmd_sync
check "a failed grant: exit 1, before any app is created" "1 none" "$rc $([ -e "$T/create" ] && echo created || echo none)"

app_id_by_name() { echo app-1; }
app_get() { jq -n '{app: {oidcConfig: {redirectUris: ["https://rooms.stale/oauth2/callback"], clientId: "CID"}}}'; }
GRANT_ADMIN=""; GRANTS=()
rm -f "$T/put"
run_cmd_sync
check "repair: cmd_sync succeeds" 0 "$rc"
check "repair: JWT kept" OIDC_TOKEN_TYPE_JWT "$(jq -r .accessTokenType "$T/put" 2>/dev/null)"

echo "== 8. --grant is parsed, and a malformed one is refused before any call =="
mkdir -p "$T/bin"
for cli in curl gcloud aws kubectl bao; do
    printf '#!/usr/bin/env bash\necho %s >> "%s/cli-calls"\nexit 1\n' "$cli" "$T" > "$T/bin/$cli"
    chmod +x "$T/bin/$cli"
done
for bad in agents-admin agents-owner=dev@x =dev@x; do
    o="$(PATH="$T/bin:$PATH" timeout 10 bash "$SRC" sync --cluster c0 --cloud gcp --grant "$bad" 2>&1)"; r=$?
    check "--grant ${bad}: exit 2, no CLI called" "2 none" "$r $([ -e "$T/cli-calls" ] && echo called || echo none)"
    grep -qF -- '--grant takes' <<<"$o" || { printf '  FAIL --grant %s: no usage message: %s\n' "$bad" "$(head -2 <<<"$o")"; fail=1; }
done

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
