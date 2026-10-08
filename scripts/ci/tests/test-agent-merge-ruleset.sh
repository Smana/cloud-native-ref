#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-merge-ruleset.sh against a PATH-stubbed gh: the merge ruleset
# (SP3 R16; owner, 2026-09-27) covers main and the revert branches, active, restricting
# creation, update and deletion, bypassed only by the human roles, Renovate and the merger
# App — the factory's App and the agents' App are on no list. No test contacts GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/agent-merge-ruleset.sh"
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
  "api /apps/ogenki-agent-merger --jq .id") echo 888 ;;
  "api repos/Smana/demo/rulesets?includes_parents=false&per_page=100") cat "$STUB_LIST" ;;
  "api --method POST "*|"api --method PUT "*) cat >"$STUB_BODY" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODY="$tmp/body" STUB_LIST="$tmp/list"

MERGER_APP_SLUG="" bash "$SUBJECT" Smana/demo >/dev/null 2>&1 && fail "refuses without MERGER_APP_SLUG"
echo '[]' >"$tmp/list"
MERGER_APP_SLUG=ogenki-agent-merger bash "$SUBJECT" Smana/demo >/dev/null 2>&1 || fail "creates"
jq -e '.name == "agent-merge" and .enforcement == "active" and .target == "branch"' "$tmp/body" >/dev/null || fail "active branch ruleset"
jq -e '.conditions.ref_name == {"include":["refs/heads/main","refs/heads/revert-*","refs/heads/revert-*/**"],"exclude":[]}' "$tmp/body" >/dev/null || fail "main and the revert branches, slash included"
jq -e '[.rules[].type] == ["creation","update","deletion"]' "$tmp/body" >/dev/null || fail "creation, update, deletion"
jq -e '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"always"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"},{"actor_id":888,"actor_type":"Integration","bypass_mode":"always"}]' "$tmp/body" >/dev/null || fail "R16: the roles, Renovate and the merger, no other App"
echo '[{"id":9,"name":"agent-merge"}]' >"$tmp/list"
: >"$tmp/log"
MERGER_APP_SLUG=ogenki-agent-merger bash "$SUBJECT" Smana/demo >/dev/null 2>&1 || fail "updates"
grep -q '^api --method PUT repos/Smana/demo/rulesets/9 ' "$tmp/log" || fail "updates in place"
[ "$fails" -eq 0 ] || exit 1
echo PASS
