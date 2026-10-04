#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-branch-ruleset.sh against a PATH-stubbed gh: it
# creates the ruleset when absent and updates the same one in place when
# present, and BOTH bodies carry every field that makes it a control: its name,
# active enforcement on branches, agent/** excluded, the three rule types and
# the bypass list (OD-7). A body with `evaluate` or `disabled` enforcement is
# audit-only and would let the agents' App merge. The split source (R16) leaves
# main and the revert branches to agent-merge, and refuses to apply until that
# ruleset exists. No test contacts GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/agent-branch-ruleset.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "$*" in
  "api /apps/renovate --jq .id") echo 2740 ;;
  "api repos/Smana/demo/rulesets?includes_parents=false&per_page=100") cat "$STUB_LIST" ;;
  "api repos/Smana/demo/rulesets/42") cat "$STUB_CURRENT" ;;
  "api --method POST "*|"api --method PUT "*) cat >"$STUB_BODY" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODY="$tmp/body" STUB_LIST="$tmp/list" \
  STUB_CURRENT="$tmp/current"

roles='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"always"}]'
renovate='{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"}'

run() { : >"$STUB_LOG"; rm -f "$STUB_BODY"; bash "$SUBJECT" Smana/demo >/dev/null 2>"$tmp/stderr" || fail "subject exited non-zero"; }

# $1 labels the run; $2 is the exact bypass list the body must carry.
check_body() {
  jq -e '.name == "agent-branches"' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: names the ruleset agent-branches"
  jq -e '.target == "branch"' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: targets branches"
  jq -e '.enforcement == "active"' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: enforcement is active"
  jq -e '.conditions.ref_name == {"include":["~ALL"],"exclude":["refs/heads/agent/**","refs/heads/main","refs/heads/revert-*","refs/heads/revert-*/**"]}' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: confines everyone else to agent/**, leaving main and the revert branches to agent-merge"
  jq -e '[.rules[].type] == ["creation","update","deletion"]' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: restricts creation, update and deletion"
  jq -e --argjson want "$2" '.bypass_actors == $want' "$STUB_BODY" >/dev/null 2>&1 || fail "$1: bypass list is exactly $2"
}

# R16: the split source refuses to apply while agent-merge is absent — main and
# the revert branches must never be uncovered.
echo '[{"id":7,"name":"other"}]' >"$STUB_LIST"
: >"$STUB_LOG"; rm -f "$STUB_BODY"
bash "$SUBJECT" Smana/demo >/dev/null 2>"$tmp/stderr" && fail "applies the split source while agent-merge is absent"
grep -q 'agent-merge first' "$tmp/stderr" || fail "refuses with agent-merge first on stderr"
if grep -qE -- '--method (POST|PUT)' "$STUB_LOG"; then fail "the refusal writes nothing"; fi

# Absent: another ruleset exists, none named agent-branches.
echo '[{"id":7,"name":"other"},{"id":8,"name":"agent-merge"}]' >"$STUB_LIST"
run
grep -q '^api --method POST repos/Smana/demo/rulesets ' "$STUB_LOG" || fail "creates the ruleset when absent"
check_body create "$(jq -c -n --argjson r "$roles" --argjson v "$renovate" '$r + [$v]')"

# Present: updates that ruleset, found by the name in the JSON source.
echo '[{"id":7,"name":"other"},{"id":8,"name":"agent-merge"},{"id":42,"name":"agent-branches"}]' >"$STUB_LIST"
jq -n --argjson r "$roles" --argjson v "$renovate" '{bypass_actors: ($r + [$v])}' >"$STUB_CURRENT"
run
grep -q '^api --method PUT repos/Smana/demo/rulesets/42 ' "$STUB_LOG" || fail "updates in place when present"
if grep -q -- '--method POST' "$STUB_LOG"; then fail "never creates a second ruleset"; fi
check_body update "$(jq -c -n --argjson r "$roles" --argjson v "$renovate" '$r + [$v]')"
if grep -q 'warning' "$tmp/stderr"; then fail "no warning when no App leaves the bypass list"; fi

# Present with an App on the live bypass list that the source no longer names.
jq -n --argjson r "$roles" --argjson v "$renovate" '{bypass_actors: ($r + [$v, {"actor_id":999,"actor_type":"Integration","bypass_mode":"always"}])}' >"$STUB_CURRENT"
run
grep -q 'warning.*999' "$tmp/stderr" || fail "warns when the update drops an App from the bypass list"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
