#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-branch-ruleset.sh against a PATH-stubbed gh: it
# applies BOTH rulesets, agent-branches and agent-tags, creating each when absent
# and updating the same one in place when present. Every body carries every
# field that makes it a control: its name, active enforcement, its target and ref
# condition, the three rule types and the bypass list (OD-7), identical in both.
# A body with `evaluate` or `disabled` enforcement is audit-only: the agents' App
# could merge, or push a tag that a `tags:` workflow fires on. No test contacts
# GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/agent-branch-ruleset.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
# A written body lands in $STUB_BODIES/<its name>, so each ruleset is checked on its own.
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  "api /apps/renovate --jq .id") echo 2740 ;;
  "api /apps/ogenki-factory --jq .id") echo 999 ;;
  "api repos/Smana/demo/rulesets?includes_parents=false&per_page=100") cat "$STUB_LIST" ;;
  "api repos/Smana/demo/rulesets/42"|"api repos/Smana/demo/rulesets/43") cat "$STUB_CURRENT" ;;
  "api --method POST "*|"api --method PUT "*)
    body="$(cat)"
    printf '%s\n' "$body" >"$STUB_BODIES/$(jq -r .name <<<"$body")" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODIES="$tmp/bodies" STUB_LIST="$tmp/list" \
  STUB_CURRENT="$tmp/current" FACTORY_APP_SLUG=""

roles='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
renovate='{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"}'
factory='{"actor_id":999,"actor_type":"Integration","bypass_mode":"always"}'
default_bypass="$(jq -c -n --argjson r "$roles" --argjson v "$renovate" '$r + [$v]')"
branches="$tmp/bodies/agent-branches"
tags="$tmp/bodies/agent-tags"

run() {
  : >"$STUB_LOG"
  rm -rf "$STUB_BODIES"
  mkdir -p "$STUB_BODIES"
  bash "$SUBJECT" Smana/demo >/dev/null 2>"$tmp/stderr" || fail "subject exited non-zero"
}
posts() { grep -c '^api --method POST repos/Smana/demo/rulesets ' "$STUB_LOG"; }

# $1 labels the run; $2 is the exact bypass list both bodies must carry.
check_bodies() {
  jq -e '.target == "branch"' "$branches" >/dev/null 2>&1 || fail "$1: agent-branches targets branches"
  jq -e '.conditions.ref_name == {"include":["~ALL"],"exclude":["refs/heads/agent/**"]}' "$branches" >/dev/null 2>&1 || fail "$1: confines everyone else to agent/**"
  jq -e '.target == "tag"' "$tags" >/dev/null 2>&1 || fail "$1: agent-tags targets tags"
  jq -e '.conditions.ref_name == {"include":["~ALL"],"exclude":[]}' "$tags" >/dev/null 2>&1 || fail "$1: agent-tags covers every tag"
  for b in "$branches" "$tags"; do
    n="$(basename "$b")"
    jq -e --arg n "$n" '.name == $n' "$b" >/dev/null 2>&1 || fail "$1: $n is applied under its own name"
    jq -e '.enforcement == "active"' "$b" >/dev/null 2>&1 || fail "$1: $n enforcement is active"
    jq -e '[.rules[].type] == ["creation","update","deletion"]' "$b" >/dev/null 2>&1 || fail "$1: $n restricts creation, update and deletion"
    jq -e --argjson want "$2" '.bypass_actors == $want' "$b" >/dev/null 2>&1 || fail "$1: $n bypass list is exactly $2"
  done
}

# Absent: another ruleset exists, neither of ours.
echo '[{"id":7,"name":"other"}]' >"$STUB_LIST"
run
[ "$(posts)" -eq 2 ] || fail "creates both rulesets when absent"
check_bodies create "$default_bypass"

# Present: updates each in place, found by the name in its JSON source.
echo '[{"id":7,"name":"other"},{"id":42,"name":"agent-branches"},{"id":43,"name":"agent-tags"}]' >"$STUB_LIST"
jq -n --argjson b "$default_bypass" '{bypass_actors: $b}' >"$STUB_CURRENT"
run
grep -q '^api --method PUT repos/Smana/demo/rulesets/42 ' "$STUB_LOG" || fail "updates agent-branches in place when present"
grep -q '^api --method PUT repos/Smana/demo/rulesets/43 ' "$STUB_LOG" || fail "updates agent-tags in place when present"
if grep -q -- '--method POST' "$STUB_LOG"; then fail "never creates a second ruleset"; fi
check_bodies update "$default_bypass"
if grep -q 'warning' "$tmp/stderr"; then fail "no warning when no App leaves the bypass list"; fi

# A repository that predates the tag ruleset: updates one, creates the other.
echo '[{"id":42,"name":"agent-branches"}]' >"$STUB_LIST"
run
grep -q '^api --method PUT repos/Smana/demo/rulesets/42 ' "$STUB_LOG" || fail "upgrade: updates agent-branches"
[ "$(posts)" -eq 1 ] || fail "upgrade: creates agent-tags only"
check_bodies upgrade "$default_bypass"

# Both present with the factory's App bypassed, re-run without FACTORY_APP_SLUG.
echo '[{"id":42,"name":"agent-branches"},{"id":43,"name":"agent-tags"}]' >"$STUB_LIST"
jq -n --argjson b "$default_bypass" --argjson f "$factory" '{bypass_actors: ($b + [$f])}' >"$STUB_CURRENT"
run
grep -q 'warning.*agent-branches.*999' "$tmp/stderr" || fail "warns when the agent-branches update drops an App"
grep -q 'warning.*agent-tags.*999' "$tmp/stderr" || fail "warns when the agent-tags update drops an App"

export FACTORY_APP_SLUG=ogenki-factory
echo '[]' >"$STUB_LIST"
run
check_bodies "create with the factory" "$(jq -c -n --argjson b "$default_bypass" --argjson f "$factory" '$b + [$f]')"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
