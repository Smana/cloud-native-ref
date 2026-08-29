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

exit "$fail"
