#!/usr/bin/env bash
# Unit-tests the three jq comparisons zitadel-idp.sh's ensure_idp/ensure_action/
# ensure_flow use to decide [ok] vs [STALE], against fixture JSON shaped like
# real ZITADEL API responses (field paths confirmed against the ZITADEL API
# reference: AddGoogleProvider/UpdateGoogleProvider, ListActions, GetFlow).
#
# zitadel-idp.sh is not sourceable -- it runs its sync unconditionally at the
# bottom of the file, against a live PAT and a live cluster -- so this restates
# each filter rather than importing it. If a filter in the script changes,
# this needs the same edit or it silently stops testing what actually runs;
# that is a known trade-off of testing inline jq in a non-library script.
set -uo pipefail
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# ── ensure_idp: .config.google.clientId ──────────────────────────────────────
idp_match='{"id":"idp1","name":"Google Workspace","config":{"google":{"clientId":"abc123"}}}'
idp_stale='{"id":"idp1","name":"Google Workspace","config":{"google":{"clientId":"OLD-ROTATED-OUT"}}}'

existing_client_id="$(jq -r '.config.google.clientId // empty' <<< "$idp_match")"
check "idp clientId read back" "abc123" "$existing_client_id"

[ "$(jq -r '.config.google.clientId // empty' <<< "$idp_match")" = "abc123" ] && idp_verdict=ok || idp_verdict=STALE
check "idp: matching clientId -> ok" "ok" "$idp_verdict"

[ "$(jq -r '.config.google.clientId // empty' <<< "$idp_stale")" = "abc123" ] && idp_verdict=ok || idp_verdict=STALE
check "idp: rotated clientId -> STALE" "STALE" "$idp_verdict"

# A Google-type entry genuinely has no issuer field to compare -- confirms
# there is nothing here for a changed IDP_URL to invalidate (see the comment
# above ensure_idp in zitadel-idp.sh for the API reference this is based on).
check "idp: no issuer field on a google-type config" "" "$(jq -r '.config.oidc.issuer // empty' <<< "$idp_match")"

# ── ensure_action: script / timeout / allowedToFail ──────────────────────────
desired_script="function groupsFromRoles(ctx, api) { /* ... */ }"
desired_timeout="10s"
desired_allowed="false"

action_match="$(jq -n --arg s "$desired_script" --arg t "$desired_timeout" \
    '{id:"act1", script:$s, timeout:$t, allowedToFail:false}')"
action_stale_script="$(jq -n --arg t "$desired_timeout" \
    '{id:"act1", script:"function groupsFromRoles(ctx, api) { return; }", timeout:$t, allowedToFail:false}')"
action_stale_timeout="$(jq -n --arg s "$desired_script" \
    '{id:"act1", script:$s, timeout:"30s", allowedToFail:false}')"

action_diffs() {
    local existing_json="$1" current_script current_timeout current_allowed diffs=()
    current_script="$(jq -r '.script // empty' <<< "$existing_json")"
    current_timeout="$(jq -r '.timeout // empty' <<< "$existing_json")"
    current_allowed="$(jq -r '.allowedToFail // false' <<< "$existing_json")"
    [ "$current_script" != "$desired_script" ] && diffs+=("script")
    [ "$current_timeout" != "$desired_timeout" ] && diffs+=("timeout")
    [ "$current_allowed" != "$desired_allowed" ] && diffs+=("allowedToFail")
    printf '%s' "${diffs[*]:-}"
}

check "action: matches on disk -> no diffs" "" "$(action_diffs "$action_match")"
check "action: script drifted -> flagged"   "script" "$(action_diffs "$action_stale_script")"
check "action: timeout drifted -> flagged"  "timeout" "$(action_diffs "$action_stale_timeout")"

# ── ensure_flow: is action_id already bound on this trigger? ─────────────────
flow='{"flow":{"triggerActions":[
  {"triggerType":{"id":"4"},"actions":[{"id":"act1"}]},
  {"triggerType":{"id":"5"},"actions":[]}
]}}'

bound4="$(jq -r --arg t "4" --arg a "act1" \
    '.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id | select(. == $a)' <<< "$flow")"
check "flow: trigger 4 already bound" "act1" "$bound4"

bound5="$(jq -r --arg t "5" --arg a "act1" \
    '.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id | select(. == $a)' <<< "$flow")"
check "flow: trigger 5 not bound" "" "$bound5"

# The empty-flow fallback ensure_flow uses when GET fails or the flow has
# never been configured -- must not make jq choke on an actually-empty
# document (an object it selects nothing from, not empty stdin).
bound_empty="$(jq -r --arg t "4" --arg a "act1" \
    '.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id | select(. == $a)' <<< '{}')"
check "flow: empty document -> not bound, no error" "" "$bound_empty"

# ── round 1 fix: the client secret must not reach jq's argv ─────────────────
#
# Static, not behavioural: a functional round-trip test can't tell "the
# secret went in via stdin" from "the secret went in via --arg" -- both jq
# constructions produce byte-identical JSON for a normal secret. Only reading
# the source distinguishes them, so that's what this checks, against the real
# file rather than a restatement of it.
HERE="$(cd "$(dirname "$0")" && pwd)"
leaks="$(grep -n -- '--arg[[:space:]]\+cs\b' "$HERE/../../provision/zitadel-idp.sh" || true)"
check "no client secret passed as a jq argv value" "" "$leaks"

# Functional companion: google_idp_payload's actual construction (restated,
# same caveat as the top of this file) round-trips a secret containing
# characters that would be easy to mis-escape.
IDP_NAME="Google Workspace"
google_idp_payload() {
    local ci="$1" cs="$2"
    printf '%s' "$cs" | jq -Rs --arg n "$IDP_NAME" --arg ci "$ci" \
        '{name: $n, clientId: $ci, clientSecret: .,
          scopes: ["openid","profile","email"],
          providerOptions: {isLinkingAllowed: true, isCreationAllowed: true,
                            isAutoCreation: true, isAutoUpdate: true}}'
}
tricky_secret='we!rd"secret\1`with`backtick\and\\backslash'
payload="$(google_idp_payload "client-123" "$tricky_secret")"
check "payload: clientId preserved"     "client-123"     "$(jq -r '.clientId' <<< "$payload")"
check "payload: tricky secret round-trips" "$tricky_secret" "$(jq -r '.clientSecret' <<< "$payload")"

# ── the real script against a fake ZITADEL ───────────────────────────────────
#
# Everything above restates a filter; this runs zitadel-idp.sh itself. curl,
# kubectl and aws are shims first on PATH: curl is a small stateful ZITADEL
# (IdPs, login policy, actions, flow 2, machine users, org members, PATs), aws
# is a secret store backed by files, kubectl hands back the admin PAT that
# resolve_zitadel_pat reads. State lives in files, so --apply followed by a dry
# run proves convergence rather than asserting it.
SCRIPT="$HERE/../../provision/zitadel-idp.sh"
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/store"

cat > "$S/bin/kubectl" <<'SHIM'
#!/usr/bin/env bash
printf 'admin-pat' | base64
SHIM

cat > "$S/bin/aws" <<'SHIM'
#!/usr/bin/env bash
# secretsmanager describe-secret | get-secret-value | create-secret | put-secret-value
sub="$2"; id=""; json=""
while [ $# -gt 0 ]; do
    case "$1" in
        --secret-id) id="$2"; shift 2 ;;
        --cli-input-json) json="${2#file://}"; shift 2 ;;
        *) shift ;;
    esac
done
f() { printf '%s/store/%s' "$FAKE_STATE" "${1//\//_}"; }
case "$sub" in
    describe-secret) [ -f "$(f "$id")" ] || { echo "ResourceNotFoundException" >&2; exit 254; } ;;
    get-secret-value) [ -f "$(f "$id")" ] || exit 254; cat "$(f "$id")" ;;
    create-secret|put-secret-value)
        name="$(jq -r '.Name // .SecretId' "$json")"
        jq -r '.SecretString' "$json" > "$(f "$name")" ;;
esac
SHIM

cat > "$S/bin/curl" <<'SHIM'
#!/usr/bin/env bash
S="$FAKE_STATE"
method=GET; url=""; data=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -d) if [ "$2" = "@-" ]; then data="$(cat)"; else data="$2"; fi; shift 2 ;;
        -K|-H|--resolve) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
path="${url#"$IDP_URL"}"
echo "$method $path" >> "$S/calls.log"
upd() { local file="$S/$1"; shift; jq "$@" "$file" > "$file.t" && mv "$file.t" "$file"; }
next() { local n; n="$(cat "$S/n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$S/n"; echo $((n + 1)); }
case "$method $path" in
    "POST /admin/v1/idps/templates/_search") jq -c '{result: .}' "$S/idps.json" ;;
    "POST /admin/v1/idps/google")
        upd idps.json --argjson d "$data" '. + [{id:"idp-google",name:"Google Workspace",config:{google:{clientId:$d.clientId}}}]'
        echo '{"id":"idp-google"}' ;;
    "POST /admin/v1/idps/github")
        echo "$data" > "$S/github-body.json"
        upd idps.json --argjson d "$data" '. + [{id:"idp-github",name:"GitHub",config:{github:{clientId:$d.clientId}}}]'
        echo '{"id":"idp-github"}' ;;
    "PUT /admin/v1/idps/"*) echo '{}' ;;
    "GET /admin/v1/policies/login") jq -c '{policy:{idps:[.[]|{idpId:.}]}}' "$S/policy.json" ;;
    "POST /admin/v1/policies/login/idps") upd policy.json --argjson d "$data" '. + [$d.idpId]'; echo '{}' ;;
    "GET /management/v1/policies/login") echo '{"policy":{"isDefault":true}}' ;;
    "POST /management/v1/actions/_search") jq -c '{result: .}' "$S/actions.json" ;;
    "POST /management/v1/actions")
        id="act-$(next)"
        upd actions.json --argjson d "$data" --arg i "$id" '. + [$d + {id:$i}]'
        echo "{\"id\":\"$id\"}" ;;
    "PUT /management/v1/actions/"*) echo '{}' ;;
    "GET /management/v1/flows/2")
        if [ -n "${FLOW_FAIL:-}" ]; then echo "curl: (22) The requested URL returned error: 500" >&2; exit 22; fi
        cat "$S/flow2.json" ;;
    "POST /management/v1/flows/2/trigger/"*)
        upd flow2.json --argjson d "$data" --arg t "${path##*/}" \
            '.flow.triggerActions = ([.flow.triggerActions[]? | select(.triggerType.id != $t)] + [{triggerType:{id:$t},actions:[$d.actionIds[]|{id:.}]}])'
        echo '{}' ;;
    "POST /management/v1/users/_search") jq -c '{result: .}' "$S/users.json" ;;
    "POST /management/v1/users/machine")
        upd users.json --argjson d "$data" '. + [{id:"reader-1",userName:$d.userName}]'
        echo '{"userId":"reader-1"}' ;;
    "POST /management/v1/orgs/me/members/_search") jq -c '{result: .}' "$S/members.json" ;;
    "POST /management/v1/orgs/me/members") upd members.json --argjson d "$data" '. + [$d]'; echo '{}' ;;
    "PUT /management/v1/orgs/me/members/"*)
        upd members.json --argjson d "$data" --arg u "${path##*/}" 'map(if .userId == $u then .roles = $d.roles else . end)'
        echo '{}' ;;
    "POST /management/v1/users/"*"/pats/_search") jq -c '{result: .}' "$S/pats.json" ;;
    "POST /management/v1/users/"*"/pats")
        id="tok-$(next)"
        upd pats.json --argjson d "$data" --arg i "$id" '. + [{id:$i,expirationDate:$d.expirationDate}]'
        echo "{\"tokenId\":\"$id\",\"token\":\"reader-pat-$id\"}" ;;
    *) echo "fake curl: unhandled $method $path" >&2; exit 22 ;;
esac
SHIM
chmod +x "$S/bin/kubectl" "$S/bin/aws" "$S/bin/curl"

reset_state() {
    rm -f "$S/calls.log" "$S/n" "$S/store"/*
    echo '[]' > "$S/idps.json"; echo '[]' > "$S/actions.json"; echo '[]' > "$S/policy.json"
    echo '[]' > "$S/users.json"; echo '[]' > "$S/members.json"; echo '[]' > "$S/pats.json"
    echo '{"flow":{"triggerActions":[]}}' > "$S/flow2.json"
    echo '{"client_id":"google-id","client_secret":"gs"}' > "$S/store/zitadel-google-idp"
}
with_github_key() { echo '{"client_id":"gh-id","client_secret":"ghs"}' > "$S/store/zitadel-github-idp"; }
sync() { # [--apply]; prints the script's output, last line is its exit status
    local out rc
    out="$(PATH="$S/bin:$PATH" FAKE_STATE="$S" IDP_URL="https://auth.test" AWS_REGION=eu-west-3 \
        bash "$SCRIPT" sync --cluster aws-0 --cloud aws "$@" 2>&1)"; rc=$?
    printf '%s\nrc=%s\n' "$out" "$rc"
}
count() { grep -cE -- "$1" <<< "$2" || true; }
calls() { grep -cE -- "$1" "$S/calls.log" 2>/dev/null || true; }

# 1. Fresh platform, GitHub key present: one plan per piece, nothing written.
reset_state; with_github_key
out="$(sync)"
check "dry run: exits 0" "rc=0" "$(tail -1 <<< "$out")"
check "dry run: plans the Google IdP once" "1" "$(count "would create IdP 'Google Workspace'" "$out")"
check "dry run: plans the GitHub IdP once" "1" "$(count "would create IdP 'GitHub'" "$out")"
check "dry run: plans the reader machine user once" "1" "$(count "would create machine user 'room-broker-idp-reader'" "$out")"
check "dry run: plans ORG_OWNER_VIEWER once" "1" "$(count "would grant ORG_OWNER_VIEWER" "$out")"
check "dry run: plans one PAT" "1" "$(count "would mint a PAT" "$out")"
check "dry run: writes nothing to ZITADEL" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"
check "dry run: writes nothing to the store" "" "$(find "$S/store" -type f ! -name 'zitadel-*-idp' -printf '%f')"

# 2. No GitHub key: skipped with a log line; Google exactly as before.
reset_state
out="$(sync)"
check "no key: GitHub IdP skipped" "1" "$(count '^\[skip   \] zitadel-github-idp' "$out")"
check "no key: no GitHub IdP planned" "0" "$(count "'GitHub'" "$out")"
check "no key: Google planned once" "1" "$(count "would create IdP 'Google Workspace'" "$out")"
check "no key: one login-policy plan (Google)" "1" "$(count 'would add .*login policy' "$out")"
check "no key: no reader" "0" "$(count 'room-broker' "$out")"

# 3. Apply, then converge: the second run plans nothing and mints nothing.
reset_state; with_github_key
out="$(sync --apply)"
check "apply: exits 0" "rc=0" "$(tail -1 <<< "$out")"
check "apply: GitHub IdP created once" "1" "$(calls '^POST /admin/v1/idps/github$')"
check "apply: GitHub IdP is link-only" '{"isLinkingAllowed":true,"isCreationAllowed":false,"isAutoCreation":false,"autoLinking":null}' \
    "$(jq -c '.providerOptions | {isLinkingAllowed, isCreationAllowed, isAutoCreation, autoLinking}' "$S/github-body.json")"
check "apply: GitHub on the login policy" "1" "$(jq -r '.[]' "$S/policy.json" | grep -c idp-github || true)"
check "apply: reader holds ORG_OWNER_VIEWER" '["ORG_OWNER_VIEWER"]' "$(jq -c '.[0].roles' "$S/members.json")"
check "apply: store key holds the PAT and githubIdpId" '{"pat":true,"githubIdpId":"idp-github"}' \
    "$(jq -c '{pat: (.pat | startswith("reader-pat-")), githubIdpId}' "$S/store/room-broker-zitadel-reader")"
out="$(sync)"
check "converged: no [dry-run] lines" "0" "$(count '^\[dry-run\]' "$out")"
check "converged: no [STALE] lines" "0" "$(count '^\[STALE' "$out")"
: > "$S/calls.log"
sync --apply > /dev/null
check "converged apply: no second PAT" "0" "$(calls '/pats$')"
check "converged apply: no mutation at all" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"

# 4. A PAT with under 30 days left is replaced.
jq '.[0].expirationDate = "'"$(date -u -d '+10 days' +%Y-%m-%dT%H:%M:%SZ)"'"' "$S/pats.json" > "$S/p.t" && mv "$S/p.t" "$S/pats.json"
out="$(sync)"
check "rotation: near-expiry PAT is stale" "1" "$(count 'would mint a PAT' "$out")"

# 5. SetTriggerActions replaces the list: an existing binding must survive.
jq '.flow.triggerActions = [{triggerType:{id:"4"},actions:[{id:"hand-bound"}]}]' "$S/flow2.json" > "$S/f.t" && mv "$S/f.t" "$S/flow2.json"
sync --apply > /dev/null
check "flow: hand-bound action kept next to ours" "2" "$(jq '[.flow.triggerActions[] | select(.triggerType.id == "4") | .actions[]] | length' "$S/flow2.json")"

# 6. GetFlow failing under --apply aborts before any binding is written.
jq '.flow.triggerActions = []' "$S/flow2.json" > "$S/f.t" && mv "$S/f.t" "$S/flow2.json"
: > "$S/calls.log"
out="$(FLOW_FAIL=1 sync --apply)"
check "GetFlow 5xx: apply exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "GetFlow 5xx: no SetTriggerActions POST" "0" "$(calls 'POST /management/v1/flows/2/trigger')"

exit "$fail"
