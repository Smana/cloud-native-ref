#!/usr/bin/env bash
# Generate SUMMARY.md from PR + git metadata at archive time.
#
# Usage: scripts/sdd/generate-summary.sh <spec-dir> <pr-number> <merge-sha> [merge-base-sha]
#
# Writes <spec-dir>/SUMMARY.md from the docs/specs/templates/SUMMARY.md template,
# auto-filling commits, files, deviations, and SC snapshot. Idempotent — re-running
# overwrites the previous SUMMARY.md.

set -euo pipefail

SPEC_DIR="${1:?spec-dir required}"
PR_NUM="${2:?pr-number required}"
MERGE_SHA="${3:?merge-sha required}"
BASE_SHA="${4:-$(git merge-base "$MERGE_SHA" main 2>/dev/null || echo "")}"

cd "$(git rev-parse --show-toplevel)"

[ -d "$SPEC_DIR" ] || { echo "error: $SPEC_DIR not found" >&2; exit 1; }

TEMPLATE="docs/specs/templates/SUMMARY.md"
[ -f "$TEMPLATE" ] || { echo "error: template missing at $TEMPLATE" >&2; exit 1; }

OUT="$SPEC_DIR/SUMMARY.md"

ISSUE_NUM=$(grep -oP 'Issue.*#\K\d+' "$SPEC_DIR/spec.md" 2>/dev/null | head -1 || echo "")
SHORT_SHA=$(git rev-parse --short "$MERGE_SHA")
TODAY=$(date -u +%Y-%m-%d)
SPEC_NUM=$(basename "$SPEC_DIR" | grep -oE '^[0-9]+' || echo "XXX")
TITLE_FROM_SPEC=$(head -1 "$SPEC_DIR/spec.md" | sed 's/^# Spec: *//')

# ----- commit list -----
COMMIT_TABLE=$(git log "${BASE_SHA}..${MERGE_SHA}" --reverse --format='| `%h` | %s |' 2>/dev/null \
  | head -50 || true)
[ -z "$COMMIT_TABLE" ] && COMMIT_TABLE='| _no commits collected_ | |'

# ----- file diffstat grouped by area -----
FILES_RAW=$(git diff --numstat "${BASE_SHA}..${MERGE_SHA}" 2>/dev/null || true)
FILES_TABLE=$(echo "$FILES_RAW" | awk '
  BEGIN { OFS="" }
  {
    add=$1; del=$2; path=$3
    area = "Other"
    if (path ~ /infrastructure\/base\/crossplane\/configuration\/kcl\//) area = "KCL composition"
    else if (path ~ /main_test\.k$/)                                       area = "KCL tests"
    else if (path ~ /^opentofu\//)                                          area = "OpenTofu"
    else if (path ~ /^docs\/specs\//)                                       area = "Spec artifacts"
    else if (path ~ /^docs\//)                                              area = "Docs"
    else if (path ~ /\.github\/workflows\//)                                area = "CI / workflows"
    else if (path ~ /^scripts\//)                                           area = "Scripts"
    else if (path ~ /\.claude\//)                                           area = "Claude config"
    else if (path ~ /(security|infrastructure|observability|tooling)\/(base|mycluster-0)\//) area = "Cluster manifests"
    files[area]++; adds[area] += add; dels[area] += del
  }
  END {
    for (a in files) printf "| %s | %d | +%d / -%d |\n", a, files[a], adds[a], dels[a]
  }' | sort)
[ -z "$FILES_TABLE" ] && FILES_TABLE='| _no files in diff_ | 0 | +0 / -0 |'

# ----- SC snapshot from spec.md -----
SC_TABLE=$(grep -oP '^- \*\*SC-\d{3}\*\*: .+' "$SPEC_DIR/spec.md" 2>/dev/null \
  | sed -E 's/- \*\*SC-([0-9]+)\*\*: (.*)/| SC-\1 | \2 | promised |/' || true)
[ -z "$SC_TABLE" ] && SC_TABLE='| _none defined_ | | |'

# ----- deviations (unchecked tasks at merge, read from plan.md Tasks section) -----
DEVIATIONS=""
if [ -f "$SPEC_DIR/plan.md" ]; then
  UNCHECKED=$(grep -P '^\s*-\s*\[ \]\s*\*\*T\d{3}\*\*' "$SPEC_DIR/plan.md" 2>/dev/null || true)
  if [ -n "$UNCHECKED" ]; then
    DEVIATIONS=$(echo "$UNCHECKED" | sed -E 's/^\s*-\s*\[ \]\s*\*?\*?(T[0-9]+)\*?\*?:?\s*(.*)/| \1 | \2 | not shipped | (fill in why) |/')
  fi
fi
[ -z "$DEVIATIONS" ] && DEVIATIONS='_None — all planned tasks completed._'

# ----- render -----
sed \
  -e "s|\[Title\]|${TITLE_FROM_SPEC}|g" \
  -e "s|SPEC-XXX|SPEC-${SPEC_NUM}|g" \
  -e "s|#XXX|#${ISSUE_NUM:-XXX}|g" \
  -e "s|#YYY|#${PR_NUM}|g" \
  -e "s|pull/YYY|pull/${PR_NUM}|g" \
  -e "s|YYYY-MM-DD|${TODAY}|g" \
  -e "s|<short-sha>|${SHORT_SHA}|g" \
  "$TEMPLATE" > "$OUT.tmp"

# Inject computed tables (replace the comment-marker placeholders)
python3 <<PY
import re, pathlib
p = pathlib.Path("$OUT.tmp")
s = p.read_text()

s = re.sub(
    r"<!-- Auto-filled: \`git log.*?-->\s*\| SHA \| Subject \|\s*\|-----\|---------\|\s*\| \`<sha>\` \| <subject> \|",
    "<!-- Auto-filled: git log -->\n\n| SHA | Subject |\n|-----|---------|\n${COMMIT_TABLE//$'\n'/\\n}",
    s, flags=re.S)

s = re.sub(
    r"<!-- Auto-filled: \`git diff.*?-->.*?\| KCL composition.*?\| Examples.*?\| \+N / -0 \|",
    "<!-- Auto-filled: git diff --numstat -->\n\n| Area | Files | +/- |\n|------|-------|-----|\n${FILES_TABLE//$'\n'/\\n}",
    s, flags=re.S)

s = re.sub(
    r"\| ID \| Criterion \| Status at merge \|\s*\|----\|-----------\|-----------------\|\s*\| SC-001 \|.*?\| SC-002 \|.*?promised \|",
    "| ID | Criterion | Status at merge |\n|----|-----------|-----------------|\n${SC_TABLE//$'\n'/\\n}",
    s, flags=re.S)

s = re.sub(
    r"<!-- Auto-filled from \`plan\.md\`.*?\| T00N \| <planned> \| <actual> \| <why> \|",
    "<!-- Auto-filled from plan.md Tasks section -->\n\n${DEVIATIONS//$'\n'/\\n}",
    s, flags=re.S)

p.write_text(s)
PY

mv "$OUT.tmp" "$OUT"
echo "wrote $OUT"
