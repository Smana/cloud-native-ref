#!/usr/bin/env bash
# The external link targets a pull request adds or changes in Markdown, one per line: what
# "External links 🔗" fetches (merge gate MC5). lychee --dump extracts them as the nightly scan
# does, code blocks skipped; a target already on the merge base is not the pull request's.
#
#   changed-targets.sh <base-sha>   (from the head's checkout, with the base fetched)
set -euo pipefail
mb=$(git merge-base "$1" HEAD)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git diff --name-only --diff-filter=AMR "$mb" HEAD -- '*.md' | while IFS= read -r f; do
  lychee --dump --scheme https --scheme http -- "$f" | sort -u >"$tmp/head"
  if git cat-file -e "$mb:$f" 2>/dev/null; then
    git show "$mb:$f" >"$tmp/base.md"
    lychee --dump --scheme https --scheme http -- "$tmp/base.md" | sort -u >"$tmp/base"
  else
    : >"$tmp/base"
  fi
  comm -13 "$tmp/base" "$tmp/head"
done | sort -u
