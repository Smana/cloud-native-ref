#!/usr/bin/env bash
# shellcheck disable=SC2034  # these feed the sourced functions, which shellcheck cannot resolve
# requires: jq
#
# The walkthrough's transcript carries every id and timestamp the docs page needs, taken from
# the Task and from GitHub (PATH-stubbed kubectl and gh), not from anyone's memory of the run.
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
# Records every call; answers as `gh api --paginate` does, one array per page.
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/Smana/cloud-native-ref/issues/2238") echo '{"number":2238,"created_at":"2026-10-07T18:38:57Z"}' ;;
  *repos/Smana/cloud-native-ref/issues/2199/timeline*)
    echo '[{"event":"labeled","label":{"name":"factory/ready"},"created_at":"2026-10-06T08:58:00Z"},
           {"event":"labeled","label":{"name":"docs"},"created_at":"2026-10-06T08:59:50Z"}]'
    echo '[{"event":"unlabeled","label":{"name":"factory/ready"},"created_at":"2026-10-06T08:59:40Z"},
           {"event":"labeled","label":{"name":"factory/ready"},"created_at":"2026-10-06T08:59:30Z"}]' ;;
  *repos/Smana/cloud-native-ref/pulls/2200/reviews*)
    echo '[{"state":"CHANGES_REQUESTED","user":{"type":"User"},"submitted_at":"2026-10-06T09:20:00Z"},
           {"state":"CHANGES_REQUESTED","user":{"type":"Bot"},"submitted_at":"2026-10-06T09:25:00Z"},
           {"state":"APPROVED","user":{"type":"User"},"submitted_at":"2026-10-06T09:40:00Z"}]' ;;
  *repos/Smana/cloud-native-ref/pulls/2201/reviews*) echo '[]' ;;
  *) echo "unexpected: gh $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"
: >"$GH_LOG"
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

# A restart adopts the issue it already opened (#2252).
ISSUE=""
[ "$(parse_args --issue 2238 && echo "$ISSUE")" = 2238 ] || fail "--issue stands in for --title and --body"
rc=0; (parse_args --title "only a title") 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "without --issue, --title and --body are both required (exit $rc)"
ISSUE=2238
open_issue 2>/dev/null
[ "${T[issue_opened]}" = 2026-10-07T18:38:57Z ] || fail "an adopted issue is timed when GitHub opened it, not now"
if grep -q 'issue create' "$GH_LOG"; then fail "an adopted issue opens a duplicate"; fi

# The owner's steps are timed by GitHub's events, not by when Enter was pressed (#2251).
ISSUE=2199 PR=2200
github_times
[ "${T[labelled]}" = 2026-10-06T08:59:30Z ] || fail "labelled: the latest factory/ready label event, across pages (${T[labelled]})"
[ "${T[changes_requested]}" = 2026-10-06T09:20:00Z ] || fail "changes_requested: the human's review, not a bot's (${T[changes_requested]})"
[ "${T[approved]}" = 2026-10-06T09:40:00Z ] || fail "approved: the approval's submitted_at (${T[approved]})"
[ "${T[revision_done]}" = 2026-10-06T09:00:00Z ] || fail "the factory's steps keep their marks"
PR=2201 T[changes_requested]=recorded T[approved]=recorded
github_times
[ "${T[changes_requested]}${T[approved]}" = recordedrecorded ] || fail "a step GitHub has no event for keeps its mark"
[ "$fails" -eq 0 ] || exit 1
echo PASS
