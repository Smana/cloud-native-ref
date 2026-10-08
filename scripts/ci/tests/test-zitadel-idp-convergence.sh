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
case "$*" in
    *"get externalsecrets"*)
        echo '{"items":[{"metadata":{"namespace":"agent-system","name":"room-broker-zitadel-reader"},"spec":{"secretStoreRef":{"name":"agents-secrets"},"data":[{"remoteRef":{"key":"zitadel-reader"}}]}}]}' ;;
    *"annotate externalsecret"*) echo "$*" >> "$FAKE_STATE/kube.log" ;;
    *) printf 'admin-pat' | base64 ;;
esac
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
        [ "$name" = "${FAIL_STORE:-}" ] && { echo "AccessDenied" >&2; exit 254; }
        jq -r '.SecretString' "$json" > "$(f "$name")" ;;
esac
SHIM

cat > "$S/bin/curl" <<'SHIM'
#!/usr/bin/env bash
S="$FAKE_STATE"
method=GET; url=""; data=""; out=/dev/null; wcode=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        -w) wcode=1; shift 2 ;;
        --data-binary) data="$(cat)"; shift 2 ;;
        -d) if [ "$2" = "@-" ]; then data="$(cat)"; else data="$2"; fi; shift 2 ;;
        -K|-H|--resolve) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
# A fake OpenBao KV v2 (the mirror's GET and POST), kept out of calls.log so
# "no ZITADEL mutation" stays checkable.
if [[ "$url" == https://bao.test/v1/* ]]; then
    echo "$method ${url#https://bao.test/v1/}" >> "$S/bao.log"
    if [ -n "${FAIL_BAO:-}" ] && [ "$method" = POST ]; then
        echo "curl: (22) The requested URL returned error: 403" >&2; exit 22
    fi
    case "$method" in
        GET) if [ -f "$S/bao.json" ]; then cat "$S/bao.json" > "$out"; [ -z "$wcode" ] || printf 200
             else [ -z "$wcode" ] || printf 404; exit 22; fi ;;
        POST) jq -c '{data: {data: .data}}' <<< "$data" > "$S/bao.json" ;;
    esac
    exit 0
fi
path="${url#"$IDP_URL"}"
echo "$method $path" >> "$S/calls.log"
# FAIL_ON is a glob over "METHOD /path": that request answers a curl-style 500.
# shellcheck disable=SC2053
if [ -n "${FAIL_ON:-}" ] && [[ "$method $path" == $FAIL_ON ]]; then
    echo "curl: (22) The requested URL returned error: 500" >&2; exit 22
fi
upd() { local file="$S/$1"; shift; jq "$@" "$file" > "$file.t" && mv "$file.t" "$file"; }
next() { local n; n="$(cat "$S/n" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$S/n"; echo $((n + 1)); }
case "$method $path" in
    "POST /admin/v1/idps/templates/_search")
        # SEARCH_FAIL_AFTER=n: every template search after the n-th fails.
        n="$(cat "$S/searches" 2>/dev/null || echo 0)"; echo $((n + 1)) > "$S/searches"
        if [ -n "${SEARCH_FAIL_AFTER:-}" ] && [ "$n" -ge "$SEARCH_FAIL_AFTER" ]; then
            echo "curl: (22) The requested URL returned error: 500" >&2; exit 22
        fi
        jq -c '{result: .}' "$S/idps.json" ;;
    "POST /admin/v1/idps/google")
        upd idps.json --argjson d "$data" '. + [{id:"idp-google",name:"Google Workspace",type:"PROVIDER_TYPE_GOOGLE",owner:"IDP_OWNER_TYPE_SYSTEM",config:{google:{clientId:$d.clientId}}}]'
        echo '{"id":"idp-google"}' ;;
    "POST /admin/v1/idps/github")
        echo "$data" > "$S/github-body.json"
        upd idps.json --argjson d "$data" '. + [{id:"idp-github",name:"GitHub",type:"PROVIDER_TYPE_GITHUB",owner:"IDP_OWNER_TYPE_SYSTEM",config:{github:{clientId:$d.clientId}}}]'
        echo '{"id":"idp-github"}' ;;
    "PUT /admin/v1/idps/"*)
        echo "$data" > "$S/idp-put-body.json"
        upd idps.json --argjson d "$data" --arg i "${path##*/}" 'map(if .id == $i then .name = $d.name else . end)'
        echo '{}' ;;
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
    rm -f "$S/calls.log" "$S/idp-put-body.json" "$S/n" "$S/searches" "$S/store"/* "$S/bao.log" "$S/bao.json" "$S/kube.log"
    echo '{"token":"bao-root"}' > "$S/store/bao-root-token"  # pragma: allowlist secret
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
check "dry run: writes nothing to the store" "" "$(find "$S/store" -type f ! -name 'zitadel-*-idp' ! -name bao-root-token -printf '%f')"

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
check "apply: store key holds the PAT, its tokenId and githubIdpId" '{"pat":true,"tokenId":true,"githubIdpId":"idp-github"}' \
    "$(jq -c '{pat: (.pat | startswith("reader-pat-")), tokenId: (.tokenId | startswith("tok-")), githubIdpId}' "$S/store/room-broker-zitadel-reader")"
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

# ── every reader write must fail the run ─────────────────────────────────────
converge() { reset_state; with_github_key; sync --apply > /dev/null; : > "$S/calls.log"; rm -f "$S/searches"; }
expire_pats() { jq 'map(.expirationDate = "'"$(date -u -d '+10 days' +%Y-%m-%dT%H:%M:%SZ)"'")' "$S/pats.json" > "$S/p.t" && mv "$S/p.t" "$S/pats.json"; }
STORE="$S/store/room-broker-zitadel-reader"

# 7. A failed member PUT/POST or trigger POST must not print success or exit 0.
converge
echo '[{"userId":"reader-1","roles":["ORG_OWNER_VIEWER","ORG_OWNER"]}]' > "$S/members.json"
out="$(FAIL_ON='PUT /management/v1/orgs/me/members/*' sync --apply)"
check "member PUT fails: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "member PUT fails: no success line" "0" "$(count '^\[updated\] room-broker' "$out")"
check "member PUT fails: no PAT minted" "0" "$(count '^\[minted' "$out")"
echo '[]' > "$S/members.json"
out="$(FAIL_ON='POST /management/v1/orgs/me/members' sync --apply)"
check "member POST fails: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "member POST fails: no success line" "0" "$(count '^\[granted\]' "$out")"
echo '{"flow":{"triggerActions":[]}}' > "$S/flow2.json"
out="$(FAIL_ON='POST /management/v1/flows/2/trigger/*' sync --apply)"
check "trigger POST fails: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "trigger POST fails: no [bound] line" "0" "$(count '^\[bound' "$out")"

# 8. The validity check follows the STORED token: a mint whose store write
#    failed is retried and never reported ok.
converge
old_id="$(jq -r .tokenId "$STORE")"
expire_pats
out="$(FAIL_STORE=room-broker-zitadel-reader sync --apply)"
check "store write fails: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "store write fails: not reported minted" "0" "$(count '^\[minted' "$out")"
check "store write fails: stored credential unchanged" "$old_id" "$(jq -r .tokenId "$STORE")"
out="$(sync)"
check "next run: re-mint planned" "1" "$(count 'would mint a PAT' "$out")"
check "next run: not reported ok" "0" "$(count '^\[ok     \] room-broker-zitadel-reader' "$out")"

# 9. An unresolvable IdP id never reaches the store.
converge
out="$(SEARCH_FAIL_AFTER=3 sync --apply)"
check "idp id unresolved: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "idp id unresolved: store keeps githubIdpId" "idp-github" "$(jq -r .githubIdpId "$STORE")"

# 10. Rotation under --apply replaces the stored PAT and its tokenId.
converge
old_pat="$(jq -r .pat "$STORE")"; old_id="$(jq -r .tokenId "$STORE")"
expire_pats
out="$(sync --apply)"
check "rotation apply: exits 0" "rc=0" "$(tail -1 <<< "$out")"
check "rotation apply: stored PAT changed" "true" "$([ "$(jq -r .pat "$STORE")" != "$old_pat" ] && echo true || echo false)"
check "rotation apply: stored tokenId changed" "true" "$([ "$(jq -r .tokenId "$STORE")" != "$old_id" ] && echo true || echo false)"
check "rotation apply: stored tokenId is the listed one" "1" "$(jq --arg i "$(jq -r .tokenId "$STORE")" '[.[] | select(.id == $i)] | length' "$S/pats.json")"

# 11. --mirror-openbao copies the blob to agents/zitadel-reader, whole.
: > "$S/ca.pem"
MIRROR=(--openbao-url https://bao.test --openbao-root-token-secret bao-root-token --openbao-ca-file "$S/ca.pem" --mirror-openbao)
bao_posts() { grep -c '^POST ' "$S/bao.log" 2>/dev/null || true; }
reset_state; with_github_key
out="$(sync "${MIRROR[@]}")"
check "mirror dry run: planned" "1" "$(count 'would mirror room-broker-zitadel-reader' "$out")"
check "mirror dry run: OpenBao untouched" "false" "$([ -e "$S/bao.log" ] && echo true || echo false)"
sync --apply "${MIRROR[@]}" > /dev/null
check "mirror: written to the mapped path" "1" "$(grep -c '^POST agents/data/zitadel-reader$' "$S/bao.log" || true)"
check "mirror: blob intact" "$(jq -cS . "$STORE")" "$(jq -cS '.data.data' "$S/bao.json")"
out="$(sync --apply "${MIRROR[@]}")"
check "mirror: the broker's ExternalSecret is force-synced" "true" "$(grep -q 'annotate externalsecret room-broker-zitadel-reader -n agent-system' "$S/kube.log" 2>/dev/null && echo true || echo false)"
check "mirror converged: no second write" "1" "$(bao_posts)"
check "mirror converged: exits 0" "rc=0" "$(tail -1 <<< "$out")"
# A rebuilt OpenBao is empty while the store still holds a valid PAT.
rm -f "$S/bao.json" "$S/bao.log"
sync --apply "${MIRROR[@]}" > /dev/null
check "mirror: refilled from the store after an OpenBao rebuild" "1" "$(bao_posts)"
check "mirror: a rotated PAT replaces the mirrored one" "true" "$(expire_pats; sync --apply "${MIRROR[@]}" > /dev/null; [ "$(jq -r .data.data.pat "$S/bao.json")" = "$(jq -r .pat "$STORE")" ] && echo true || echo false)"
rm -f "$S/bao.json"
out="$(FAIL_BAO=1 sync --apply "${MIRROR[@]}")"
check "mirror: refused write fails the run" "1" "$(count '^rc=[1-9]' "$out")"
reset_state; with_github_key
sync --apply > /dev/null
check "no flag: OpenBao never called" "false" "$([ -e "$S/bao.log" ] && echo true || echo false)"
reset_state
out="$(sync --apply "${MIRROR[@]}")"
check "no GitHub key: mirror skipped, run still ok" "rc=0" "$(tail -1 <<< "$out")"
check "no GitHub key: OpenBao never called" "false" "$([ -e "$S/bao.log" ] && echo true || echo false)"

# 12. A PAT without the instance role stops the run with one clear message, before
#     any step can read the 403 as "nothing exists".
reset_state; with_github_key
out="$(FAIL_ON='GET /admin/v1/policies/login' sync --apply)"
check "no instance role: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "no instance role: names IAM_OWNER" "1" "$(count 'lacks the INSTANCE role IAM_OWNER' "$out")"
check "no instance role: nothing written" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"

# 13. A hand-made Google IdP with no name is adopted, never duplicated.
unnamed_google() { echo '[{"id":"293295084030403016","name":"","type":"PROVIDER_TYPE_GOOGLE","owner":"IDP_OWNER_TYPE_SYSTEM","config":{"google":{"clientId":"old-id"}}}]' > "$S/idps.json"; }
reset_state; unnamed_google
out="$(sync)"
check "unnamed Google dry run: adoption announced" "1" "$(count "^\[adopt  \] Google IdP 293295084030403016 has name '', renaming to 'Google Workspace'" "$out")"
check "unnamed Google dry run: no create planned" "0" "$(count "would create IdP 'Google Workspace'" "$out")"
check "unnamed Google dry run: nothing written" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"
reset_state; unnamed_google; echo '["293295084030403016"]' > "$S/policy.json"
out="$(sync --apply)"
check "unnamed Google apply: exits 0" "rc=0" "$(tail -1 <<< "$out")"
check "unnamed Google apply: no create call" "0" "$(calls '^POST /admin/v1/idps/google$')"
check "unnamed Google apply: renamed through PUT by id" "1" "$(calls '^PUT /admin/v1/idps/google/293295084030403016$')"
check "unnamed Google apply: PUT carries name and client id" '["Google Workspace","google-id"]' "$(jq -c '[.name, .clientId]' "$S/idp-put-body.json" 2>/dev/null)"
check "unnamed Google apply: still one IdP, renamed" '["Google Workspace"]' "$(jq -c '[.[] | select(.type == "PROVIDER_TYPE_GOOGLE") | .name]' "$S/idps.json")"
check "unnamed Google apply: login policy lists the adopted id" "1" "$(jq -r '.[]' "$S/policy.json" | grep -c 293295084030403016 || true)"
out="$(sync)"
check "unnamed Google converged: no adopt, no dry-run lines" "0" "$(count '^\[(adopt|dry-run)' "$out")"

# 14. Two Google templates and none named: stop, write nothing.
reset_state; unnamed_google
jq '. + [{"id":"second","name":"Other","type":"PROVIDER_TYPE_GOOGLE","owner":"IDP_OWNER_TYPE_SYSTEM","config":{"google":{"clientId":"x"}}}]' "$S/idps.json" > "$S/i.t" && mv "$S/i.t" "$S/idps.json"
out="$(sync --apply)"
check "two Google IdPs: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "two Google IdPs: names both ids" "1" "$(count '293295084030403016 second' "$out")"
check "two Google IdPs: no write" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"

# 15. A failed template search under --apply must not fall through to create.
reset_state
out="$(SEARCH_FAIL_AFTER=0 sync --apply)"
check "search fails: exits non-zero" "1" "$(count '^rc=[1-9]' "$out")"
check "search fails: no create" "0" "$(calls '^POST /admin/v1/idps/(google|github)$')"
check "search fails: no write" "0" "$(grep -cvE '_search|^GET ' "$S/calls.log" || true)"

# 16. GitHub adoption follows the type, not the name.
reset_state; with_github_key
echo '[{"id":"g-only","name":"","type":"PROVIDER_TYPE_GOOGLE","owner":"IDP_OWNER_TYPE_SYSTEM","config":{"google":{"clientId":"google-id"}}}]' > "$S/idps.json"
out="$(sync --apply)"
check "unnamed Google is not adopted as GitHub: GitHub created" "1" "$(calls '^POST /admin/v1/idps/github$')"
check "unnamed Google is not adopted as GitHub: no github PUT" "0" "$(calls '^PUT /admin/v1/idps/github/')"
reset_state; with_github_key
echo '[{"id":"gh-hand","name":"","type":"PROVIDER_TYPE_GITHUB","owner":"IDP_OWNER_TYPE_SYSTEM","config":{"github":{"clientId":"old-gh"}}}]' > "$S/idps.json"
out="$(sync --apply)"
check "unnamed GitHub: adoption announced" "1" "$(count "^\[adopt  \] GitHub IdP gh-hand has name '', renaming to 'GitHub'" "$out")"
check "unnamed GitHub: no github create" "0" "$(calls '^POST /admin/v1/idps/github$')"
check "unnamed GitHub: renamed through the github PUT" "1" "$(calls '^PUT /admin/v1/idps/github/gh-hand$')"
check "unnamed GitHub: PUT keeps the link-only options" '{"isLinkingAllowed":true,"isCreationAllowed":false,"isAutoCreation":false,"isAutoUpdate":false}' \
    "$(jq -c '.providerOptions' "$S/idp-put-body.json" 2>/dev/null)"

exit "$fail"
