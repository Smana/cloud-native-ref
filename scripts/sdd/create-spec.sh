#!/usr/bin/env bash
# Create a new SDD spec: GitHub issue + spec directory with 3 artifact files.
#
# Usage: scripts/sdd/create-spec.sh <type> "<description>"
#   <type>        composition | infrastructure | security | platform
#   <description> Short feature description (used for title and slug)
#
# Creates:
#   docs/specs/NNN-slug/spec.md            — WHAT (contract; freeze after approval)
#   docs/specs/NNN-slug/plan.md            — HOW + Tasks + Review Checklist (may evolve)
#   docs/specs/NNN-slug/clarifications.md  — append-only decisions log
#
# Outputs to stdout (one key=value per line):
#   spec_num=003
#   slug=valkey-caching
#   spec_dir=docs/specs/003-valkey-caching
#   issue_url=https://github.com/...
#   issue_num=1312

set -euo pipefail

TYPE="${1:?type required}"
DESCRIPTION="${2:?description required}"

case "$TYPE" in
  composition|infrastructure|security|platform) ;;
  *)
    echo "error: invalid type '$TYPE' (must be composition|infrastructure|security|platform)" >&2
    exit 2
    ;;
esac

cd "$(git rev-parse --show-toplevel)"

# Next spec number — look in active + archived (flat-file legacy + quarterly buckets)
MAX_NUM=$(find docs/specs -name "spec.md" -path "*/[0-9]*" 2>/dev/null \
  | sed 's|.*/\([0-9][0-9]*\)-.*|\1|' \
  | sort -rn | head -1)
LEGACY_MAX=$(find docs/specs/done -maxdepth 2 -name '[0-9]*-*.md' -type f 2>/dev/null \
  | sed 's|.*/\([0-9][0-9]*\)-.*|\1|' \
  | sort -rn | head -1)
MAX_NUM=$(printf '%s\n%s\n' "${MAX_NUM:-0}" "${LEGACY_MAX:-0}" | sort -rn | head -1)
SPEC_NUM=$(printf "%03d" $((10#${MAX_NUM:-0} + 1)))

# Slug: lowercase, strip punctuation, take up to 4 meaningful words, kebab-case
SLUG=$(echo "$DESCRIPTION" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -cs 'a-z0-9' ' ' \
  | awk '{
      stop="a an the is are was were be been being have has had do does did will would could should may might must can to of in on at by for with from and or but not as if then else add new";
      split(stop, s, " "); for (i in s) stopw[s[i]]=1;
      out=""; c=0;
      for (i=1; i<=NF; i++) if (!stopw[$i] && length($i) > 2 && c < 4) { out = out (c?"-":"") $i; c++; }
      print out
    }')

SPEC_DIR="docs/specs/${SPEC_NUM}-${SLUG}"
TITLE=$(echo "$DESCRIPTION" | sed 's/^./\U&/')

TEMPLATES_DIR="docs/specs/templates"
for tpl in spec.md plan.md clarifications.md; do
  if [ ! -f "$TEMPLATES_DIR/$tpl" ]; then
    echo "error: template not found at $TEMPLATES_DIR/$tpl" >&2
    exit 3
  fi
done

# Create GitHub issue (spec anchor for discussion)
ISSUE_URL=$(gh issue create \
  --title "[SPEC] ${TITLE}" \
  --label "spec,spec:draft" \
  --body "## Summary
${DESCRIPTION}

## Type
${TYPE}

## Spec Directory
\`${SPEC_DIR}/\`

The spec is a 3-file directory:
- \`spec.md\` — contract (WHAT + why)
- \`plan.md\` — design, tasks, 4-persona review checklist
- \`clarifications.md\` — append-only decisions log

---
_Spec anchor for discussion. See \`${SPEC_DIR}/\` for the full specification._")

ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
TODAY=$(date +%Y-%m-%d)

# Create directory and instantiate the 3 artifacts
mkdir -p "$SPEC_DIR"

instantiate() {
  local template="$1"
  local output="$2"
  sed \
    -e "s|SPEC-XXX|SPEC-${SPEC_NUM}|g" \
    -e "s|#XXX|#${ISSUE_NUM}|g" \
    -e "s|issues/XXX|issues/${ISSUE_NUM}|g" \
    -e "s|pull/YYY|pull/YYY|g" \
    -e "s|YYYY-MM-DD|${TODAY}|g" \
    -e "s|\[Title\]|${TITLE}|g" \
    -e "s|composition | infrastructure | security | platform|${TYPE}|" \
    -e "s|draft | in-review | approved | implementing | done|draft|" \
    "$TEMPLATES_DIR/${template}" > "${SPEC_DIR}/${output}"
}

instantiate spec.md            spec.md
instantiate plan.md            plan.md
instantiate clarifications.md  clarifications.md

# Link spec back to issue
gh issue comment "$ISSUE_NUM" \
  --body "Spec created — 3 artifacts under [\`${SPEC_DIR}/\`](../blob/main/${SPEC_DIR}/):
- [\`spec.md\`](../blob/main/${SPEC_DIR}/spec.md) — contract (WHAT)
- [\`plan.md\`](../blob/main/${SPEC_DIR}/plan.md) — design + tasks + review checklist (HOW)
- [\`clarifications.md\`](../blob/main/${SPEC_DIR}/clarifications.md) — append-only decisions log" >/dev/null

# Machine-parseable output
cat <<EOF
spec_num=${SPEC_NUM}
slug=${SLUG}
spec_dir=${SPEC_DIR}
issue_url=${ISSUE_URL}
issue_num=${ISSUE_NUM}
EOF
