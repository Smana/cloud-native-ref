#!/usr/bin/env bash
# requires: jq
#
# scripts/ops/github/agent-merge-gate-ruleset.sh against a PATH-stubbed gh: the ruleset
# requires policy-bot: main FROM policy-bot's App (an expected source statuses:write cannot
# forge), on the default branch, active, with exactly OD-7's bypass list. No test contacts GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/agent-merge-gate-ruleset.sh"
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
  "api /apps/ogenki-merge-gate --jq .id") echo 777 ;;
  "api repos/Smana/demo/rulesets?includes_parents=false&per_page=100") cat "$STUB_LIST" ;;
  "api --method POST "*|"api --method PUT "*) cat >"$STUB_BODY" ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_BODY="$tmp/body" STUB_LIST="$tmp/list"

POLICY_BOT_APP_SLUG="" bash "$SUBJECT" Smana/demo >/dev/null 2>&1 && fail "refuses without POLICY_BOT_APP_SLUG"
echo '[]' >"$tmp/list"
POLICY_BOT_APP_SLUG=ogenki-merge-gate bash "$SUBJECT" Smana/demo >/dev/null 2>&1 || fail "creates"
jq -e '.name == "agent-merge-gate" and .enforcement == "active" and .target == "branch"' "$tmp/body" >/dev/null || fail "active branch ruleset"
jq -e '.conditions.ref_name.include == ["~DEFAULT_BRANCH"]' "$tmp/body" >/dev/null || fail "the default branch"
jq -e '.rules[0].parameters.required_status_checks == [{"context":"policy-bot: main","integration_id":777}]' "$tmp/body" >/dev/null || fail "policy-bot: main from policy-bot's App"
jq -e '.bypass_actors == [{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"},{"actor_id":2740,"actor_type":"Integration","bypass_mode":"always"}]' "$tmp/body" >/dev/null || fail "OD-7: admin for PRs only, Renovate always"
echo '[{"id":9,"name":"agent-merge-gate"}]' >"$tmp/list"
: >"$tmp/log"
POLICY_BOT_APP_SLUG=ogenki-merge-gate bash "$SUBJECT" Smana/demo >/dev/null 2>&1 || fail "updates"
grep -q '^api --method PUT repos/Smana/demo/rulesets/9 ' "$tmp/log" || fail "updates in place"
[ "$fails" -eq 0 ] || exit 1
echo PASS
