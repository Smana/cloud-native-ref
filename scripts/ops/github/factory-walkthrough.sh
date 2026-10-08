#!/usr/bin/env bash
# The dark factory's developer journey, driven live for the owner's UX checkpoint (SP3 phase 10):
# a labelled issue, the room, "Request changes", an approval, the close (no merge before the wave,
# R32; the gate's "would auto-merge" shows where it would have merged). The executor runs it; every
# human step is the owner's, prompted and waited for. The transcript it writes is what the docs
# page and its diagram are built from (scripts/docs/factory-journey.py).
#
# usage: factory-walkthrough.sh (--title "<issue title>" --body "<issue body>" | --issue <number>)
#                               [--repo owner/name] [--out transcript.json] [--timeout-min 60]
# The issue describes a real defect in a file on main: runs clone main (Task 1.13 Step 2). A restart
# passes --issue with the issue the first run opened, or it files a duplicate (#2252).
set -euo pipefail

REPO=Smana/cloud-native-ref OUT=walkthrough-transcript.json TIMEOUT=60 NS=agent-system
declare -A T=()
ISSUE="" TASK="" PR="" ROOM="" COMMENTS='[]' TITLE="" BODY=""

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mark() { T[$1]="$(now)"; printf '[%s] %s\n' "${T[$1]}" "$1" >&2; }
ask() { printf '\n>>> OWNER: %s\n    Press Enter when done. ' "$1" >&2; read -r _ </dev/tty; }
task_json() { kubectl get task -n "$NS" -l "agents.ogenki.io/issue=$ISSUE" -o json | jq '.items | last'; }
phase_in() { local p; p="$(task_json | jq -r '.status.phase // ""')"; for want in "$@"; do [ "$p" = "$want" ] && return 0; done; return 1; }
comment_has() { gh issue view "$ISSUE" --repo "$REPO" --json comments -q '.comments[].body' | grep -q "$1"; }
has_task() { [ "$(task_json)" != "null" ]; }
has_pr() { [ "$(task_json | jq -r '.status.pullRequest.number // empty')" != "" ]; }

wait_for() { # $1 what, then a command that succeeds once it is there
  local what=$1 deadline=$(( $(date +%s) + TIMEOUT * 60 ))
  shift
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || { echo "timed out after ${TIMEOUT} min waiting for: $what" >&2; exit 1; }
    sleep 10
  done
}

open_issue() {
  if [ -n "$ISSUE" ]; then
    T[issue_opened]="$(gh api "repos/$REPO/issues/$ISSUE" | jq -r .created_at)"
    return
  fi
  ISSUE="$(gh issue create --repo "$REPO" --title "$TITLE" --body "$BODY" | sed 's#.*/##')"
  mark issue_opened
  echo "a restart resumes this walkthrough with: --issue $ISSUE" >&2
}

# The owner's steps as GitHub recorded them: their marks are when Enter was pressed, so they carry
# the owner's latency (#2251). A step GitHub has no event for keeps its mark.
github_times() {
  local timeline reviews
  timeline="$(gh api --paginate "repos/$REPO/issues/$ISSUE/timeline?per_page=100")"
  reviews="$(gh api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100")"
  latest_into labelled "$timeline" 'select(.event == "labeled" and .label.name == "factory/ready") | .created_at'
  latest_into changes_requested "$reviews" 'select(.state == "CHANGES_REQUESTED" and .user.type == "User") | .submitted_at'
  latest_into approved "$reviews" 'select(.state == "APPROVED" and .user.type == "User") | .submitted_at'
}
latest_into() { # $1 the mark, $2 paged JSON arrays, $3 a filter over one element yielding a time
  local at
  at="$(jq -rn "[inputs | .[] | $3] | last // empty" <<<"$2")"
  if [ -n "$at" ]; then T[$1]=$at; fi
}

transcript() {
  local tj ts
  tj="$(task_json)"
  ts="$(for k in "${!T[@]}"; do printf '%s\t%s\n' "$k" "${T[$k]}"; done | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add')"
  jq -n --arg repo "$REPO" --argjson issue "$ISSUE" --arg task "$TASK" --arg room "$ROOM" --argjson pr "${PR:-0}" \
    --argjson t "$tj" --argjson ts "$ts" --argjson comments "$COMMENTS" '{
      repo: $repo, issue: $issue, task: $task, room: $room, pr: $pr,
      template: $t.spec.template, class: $t.spec.predictedClass, tier: $t.spec.budget.tier,
      runs: [$t.status.runs[] | {id, role, trigger, reason, tokens}],
      tokens: $t.status.usage.tokens, phase: $t.status.phase, comments: $comments, timestamps: $ts}'
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO=$2; shift 2 ;;
      --out) OUT=$2; shift 2 ;;
      --timeout-min) TIMEOUT=$2; shift 2 ;;
      --title) TITLE=$2; shift 2 ;;
      --body) BODY=$2; shift 2 ;;
      --issue) ISSUE=$2; shift 2 ;;
      *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
  done
  if [ -z "$ISSUE" ] && { [ -z "$TITLE" ] || [ -z "$BODY" ]; }; then
    echo "--title and --body are required without --issue: a real defect in a file on main" >&2; exit 2
  fi
}

main() {
  parse_args "$@"
  open_issue
  ask "apply the label factory/ready to issue #$ISSUE: a maintainer's label is what starts the factory"
  mark labelled
  wait_for "the task" has_task
  TASK="$(task_json | jq -r .metadata.name)"
  ROOM="https://rooms.${PRIVATE_DOMAIN:-priv.aws.ogenki.io}/r/$TASK"
  mark task_created
  wait_for "the 'started' comment" comment_has "started run"
  mark started_comment
  printf '\nWatch the agent work in the room: %s (tailnet)\n' "$ROOM" >&2
  wait_for "the pull request" has_pr
  PR="$(task_json | jq -r .status.pullRequest.number)"
  mark pr_opened
  wait_for "the task to wait for a review" phase_in AwaitingHuman AwaitingCI
  mark awaiting_review
  ask "on #$PR, submit a review with 'Request changes' asking for one concrete, checkable change"
  mark changes_requested
  wait_for "the revision" comment_has "revising after"
  mark revision_started
  wait_for "the revision to finish" phase_in AwaitingHuman AwaitingCI
  mark revision_done
  ask "approve #$PR"
  mark approved
  ask "close #$PR unmerged: nothing merges before the wave (R32)"
  wait_for "the task to end" phase_in Closed
  mark ended
  COMMENTS="$(gh issue view "$ISSUE" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.author.login == "ogenki-agent-factory") | {at: .createdAt, body}]')"
  github_times
  transcript >"$OUT"
  echo "transcript: $OUT" >&2
}

[ -n "${WALKTHROUGH_SOURCE_ONLY:-}" ] && return 0
main "$@"
