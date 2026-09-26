#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-branch-ruleset.sh against a PATH-stubbed gh: it
# creates the ruleset when absent, updates it in place when present, and sends
# the bypass list (OD-7): every human role that can push, Renovate, and the
# factory's App when named, so only the agents' App is confined. No test
# contacts GitHub.
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
  "api /apps/ogenki-factory --jq .id") echo 999 ;;
  "api repos/Smana/demo/rulesets --jq "*) if [ -n "$STUB_EXISTING" ]; then echo "$STUB_EXISTING"; fi ;;
  "api --method POST "*|"api --method PUT "*) cat >"$STUB_BODY" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODY="$tmp/body" STUB_EXISTING="" FACTORY_APP_SLUG=""

run() { : >"$STUB_LOG"; rm -f "$STUB_BODY"; bash "$SUBJECT" Smana/demo >/dev/null || fail "subject exited non-zero"; }

run
grep -q '^api --method POST repos/Smana/demo/rulesets ' "$STUB_LOG" || fail "creates the ruleset when absent"
jq -e '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"}]' "$STUB_BODY" >/dev/null || fail "bypass is the admin, maintain and write roles and Renovate, always"
jq -e '.conditions.ref_name == {"include":["~ALL"],"exclude":["refs/heads/agent/**"]}' "$STUB_BODY" >/dev/null || fail "confines everyone else to agent/**"
jq -e '[.rules[].type] == ["creation","update","deletion"]' "$STUB_BODY" >/dev/null || fail "restricts creation, update and deletion"

export STUB_EXISTING=42
run
grep -q '^api --method PUT repos/Smana/demo/rulesets/42 ' "$STUB_LOG" || fail "updates in place when present"
if grep -q -- '--method POST' "$STUB_LOG"; then fail "never creates a second ruleset"; fi

export STUB_EXISTING="" FACTORY_APP_SLUG=ogenki-factory
run
jq -e '[.bypass_actors[].actor_id] == [5, 2, 4, 2740, 999]' "$STUB_BODY" >/dev/null || fail "adds the factory's App when named"

[ "$fails" -eq 0 ] || exit 1
echo "PASS"
