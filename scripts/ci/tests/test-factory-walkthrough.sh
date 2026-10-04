#!/usr/bin/env bash
# shellcheck disable=SC2034  # these feed the sourced functions, which shellcheck cannot resolve
# requires: jq
#
# The walkthrough's transcript carries every id and timestamp the docs page needs, taken from
# the Task (a PATH-stubbed kubectl), not from anyone's memory of the run.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../../ops/github/factory-walkthrough.sh"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"items":[{"metadata":{"name":"3buqdlot"},"spec":{"template":"pair","predictedClass":"review","budget":{"tier":"standard"}},
 "status":{"phase":"Done","usage":{"tokens":812000},"pullRequest":{"number":2200},
   "runs":[{"id":"aaaaaaaa","role":"implementer","trigger":"initial","reason":"agent_finished","tokens":400000},
           {"id":"bbbbbbbb","role":"reviewer","trigger":"review","reason":"agent_finished","tokens":112000},
           {"id":"cccccccc","role":"implementer","trigger":"human","reason":"agent_finished","tokens":300000}]}}]}
JSON
STUB
chmod +x "$tmp/bin/kubectl"
export PATH="$tmp/bin:$PATH"
# shellcheck disable=SC1090
WALKTHROUGH_SOURCE_ONLY=1 source "$SUBJECT"
REPO=Smana/cloud-native-ref ISSUE=2199 TASK=3buqdlot PR=2200 ROOM=https://rooms.example/r/3buqdlot
for k in issue_opened labelled task_created started_comment pr_opened awaiting_review changes_requested revision_started revision_done approved ended; do
  T[$k]="2026-10-06T09:00:00Z"
done
COMMENTS='[{"at":"2026-10-06T09:01:00Z","body":"started run"}]'
out="$(transcript)"
jq -e '.issue == 2199 and .task == "3buqdlot" and .pr == 2200 and .template == "pair" and .tokens == 812000' <<<"$out" >/dev/null || fail "ids and totals"
jq -e '[.runs[].trigger] == ["initial","review","human"]' <<<"$out" >/dev/null || fail "every run and why it ran"
jq -e '.timestamps | length == 11' <<<"$out" >/dev/null || fail "eleven timestamps"
jq -e '.comments[0].body == "started run"' <<<"$out" >/dev/null || fail "the factory's comments"
[ "$fails" -eq 0 ] || exit 1
echo PASS
