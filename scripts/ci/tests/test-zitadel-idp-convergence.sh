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

# ── GitHub identity: the github_login claim (spec D7) ────────────────────────
#
# zitadel-idp.sh cannot run offline (it needs a live PAT), so the wiring a dry
# run would print is checked in the source, and the Actions are executed
# against stubbed ZITADEL contexts.
ACTIONS="$HERE/../../provision/zitadel-actions"
SCRIPT="$HERE/../../provision/zitadel-idp.sh"
LINK="$ACTIONS/github-login-on-link.js"
CLAIM="$ACTIONS/github-login-claim.js"

# One function per file, named like the Action (assert_action_name_matches_function).
check "on-link file defines githubLoginOnLink" "1" "$(grep -cE '^function githubLoginOnLink\(' "$LINK" 2>/dev/null || true)"
check "on-link file defines one function"      "1" "$(grep -cE '^function ' "$LINK" 2>/dev/null || true)"
check "claim file defines githubLoginClaim"    "1" "$(grep -cE '^function githubLoginClaim\(' "$CLAIM" 2>/dev/null || true)"
check "claim file defines one function"        "1" "$(grep -cE '^function ' "$CLAIM" 2>/dev/null || true)"

check "script creates the GitHub IdP once" "1" "$(grep -c 'api POST /admin/v1/idps/github' "$SCRIPT")"
check "flow 1 / trigger 1 (External Authentication, Post Authentication)" "1" \
    "$(grep -c '^bind_action githubLoginOnLink github-login-on-link.js 1 "External Authentication" 1$' "$SCRIPT")"
check "flow 2 / triggers 4 5 (Complement Token)" "1" \
    "$(grep -c '^bind_action githubLoginClaim github-login-claim.js 2 "CustomiseToken" 4 5$' "$SCRIPT")"
check "absent GitHub store key skips, not fails" "1" "$(grep -c '^        echo "\[skip   \] ${GITHUB_IDP_SECRET_KEY} not in' "$SCRIPT")"

# Binding a second Action must keep the first: SetTriggerActions replaces the list.
flow2='{"flow":{"triggerActions":[{"triggerType":{"id":"4"},"actions":[{"id":"groups"}]}]}}'
check "flow: POST keeps already-bound actions" '["groups","claim"]' \
    "$(jq -c --arg t 4 --arg a claim '[.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[]?.id] + [$a]' <<< "$flow2")"

run_action() { # <file> <function> <ctx json> -> JSON of what the Action wrote
    node -e '
      const fs = require("fs");
      const [file, fn, ctxJson] = process.argv.slice(1);
      const ctx = JSON.parse(ctxJson), out = {meta: {}, claims: {}};
      const md = ctx.v1.user && ctx.v1.user.md;
      if (md) { ctx.v1.user.getMetadata = () => md; }
      const api = {v1: {user: {appendMetadataRaw: (k, v) => { out.meta[k] = v; }},
                        claims: {setClaim: (k, v) => { out.claims[k] = v; }}}};
      new Function("ctx", "api", fs.readFileSync(file, "utf8") + "\n;" + fn + "(ctx, api);")(ctx, api);
      console.log(JSON.stringify(out));' "$@" 2>&1
}
EMPTY='{"meta":{},"claims":{}}'
check "link: GitHub providerInfo.login is remembered" '{"meta":{"github_login":"Smana"},"claims":{}}' \
    "$(run_action "$LINK" githubLoginOnLink '{"v1":{"externalUser":{"externalId":"1"},"providerInfo":{"login":"Smana"}}}')"
check "link: Google login (no providerInfo.login) writes nothing" "$EMPTY" \
    "$(run_action "$LINK" githubLoginOnLink '{"v1":{"externalUser":{"externalId":"1"},"providerInfo":{"email":"a@b.c"}}}')"
check "link: never falls back to a preferredUsername" "$EMPTY" \
    "$(run_action "$LINK" githubLoginOnLink '{"v1":{"externalUser":{"preferredUsername":"a@b.c"},"providerInfo":{}}}')"
check "claim: metadata becomes the github_login claim" '{"meta":{},"claims":{"github_login":"Smana"}}' \
    "$(run_action "$CLAIM" githubLoginClaim '{"v1":{"user":{"md":{"count":1,"metadata":[{"key":"github_login","value":"Smana"}]}}}}')"
check "claim: JSON-quoted metadata value is unquoted" '{"meta":{},"claims":{"github_login":"Smana"}}' \
    "$(run_action "$CLAIM" githubLoginClaim '{"v1":{"user":{"md":{"count":1,"metadata":[{"key":"github_login","value":"\"Smana\""}]}}}}')"
check "claim: byte-array metadata value is decoded" '{"meta":{},"claims":{"github_login":"Smana"}}' \
    "$(run_action "$CLAIM" githubLoginClaim '{"v1":{"user":{"md":{"count":1,"metadata":[{"key":"github_login","value":[83,109,97,110,97]}]}}}}')"
check "claim: no metadata -> no claim" "$EMPTY" \
    "$(run_action "$CLAIM" githubLoginClaim '{"v1":{"user":{"md":{"count":0,"metadata":[]}}}}')"
check "claim: other metadata keys ignored" "$EMPTY" \
    "$(run_action "$CLAIM" githubLoginClaim '{"v1":{"user":{"md":{"count":1,"metadata":[{"key":"x","value":"y"}]}}}}')"

exit "$fail"
