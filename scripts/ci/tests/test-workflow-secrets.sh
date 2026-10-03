#!/usr/bin/env bash
# requires: python3
#
# T8: a pull_request workflow may reference GITHUB_TOKEN and no other secret; agent branches
# live in this repo, so their PRs run with its secrets.
# External review R01: such a workflow also grants no write permission, at workflow level
# or in a job outside the script's allowlist.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../check-workflow-secrets.sh"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
d="$(mktemp -d)"
cat >"$d/ok.yml" <<'EOF'
on: {pull_request: {}}
jobs: {a: {runs-on: x, steps: [{run: "echo ${{ secrets.GITHUB_TOKEN }}"}]}}
EOF
cat >"$d/push-only.yml" <<'EOF'
on: {push: {branches: [main]}}
jobs: {a: {runs-on: x, steps: [{run: "echo ${{ secrets.DEPLOY_KEY }}"}]}}
EOF
WORKFLOWS_DIR="$d" bash "$SUBJECT" >/dev/null 2>&1 || fail "GITHUB_TOKEN, and secrets on push-only workflows, pass"
cat >"$d/push-gated-run.yml" <<'EOF'
on: {pull_request: {}}
jobs: {notify-main-broken: {if: "github.event_name == 'push'", runs-on: x, permissions: {issues: write}, steps: [{run: "echo ok"}]}}
EOF
WORKFLOWS_DIR="$d" bash "$SUBJECT" >/dev/null 2>&1 || fail "a push-gated allowlisted job with a run: step passes"
cat >"$d/bad.yml" <<'EOF'
on:
  pull_request_target:
jobs: {a: {runs-on: x, steps: [{run: "echo ${{ secrets.SLACK_WEBHOOK }}"}]}}
EOF
out="$(WORKFLOWS_DIR="$d" bash "$SUBJECT" 2>&1)" && fail "a pull_request_target workflow with a secret fails"
grep -q 'bad.yml.*SLACK_WEBHOOK' <<<"$out" || fail "the failure names the file and the secret"
cat >"$d/wf-write.yml" <<'EOF'
on: {pull_request: {}}
permissions: {contents: write}
jobs: {a: {runs-on: x, steps: [{run: "echo ok"}]}}
EOF
out="$(WORKFLOWS_DIR="$d" bash "$SUBJECT" 2>&1)" && fail "a pull_request workflow with a workflow-level write permission fails"
grep -q 'wf-write.yml.*contents' <<<"$out" || fail "the failure names the file and the permission"
cat >"$d/job-write.yml" <<'EOF'
on: {pull_request: {}}
jobs:
  upload: {runs-on: x, permissions: {security-events: write}, steps: [{run: "echo ok"}]}
EOF
out="$(WORKFLOWS_DIR="$d" bash "$SUBJECT" 2>&1)" && fail "a pull_request workflow with an unlisted job holding write fails"
grep -q 'job-write.yml.*upload' <<<"$out" || fail "the failure names the file and the job"
cat >"$d/ungated-run.yml" <<'EOF'
on: {pull_request: {}}
jobs: {notify-main-broken: {runs-on: x, permissions: {issues: write}, steps: [{run: "echo ok"}]}}
EOF
out="$(WORKFLOWS_DIR="$d" bash "$SUBJECT" 2>&1)" && fail "an allowlisted job with a run: step and no push gate fails"
grep -q 'ungated-run.yml.*notify-main-broken' <<<"$out" || fail "the failure names the file and the job"
[ "$fails" -eq 0 ] || exit 1
echo PASS
