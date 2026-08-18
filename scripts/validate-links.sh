#!/usr/bin/env bash
#
# validate-links.sh — resolve every relative Markdown link in the repo.
#
# A string match on a path (`git grep 'docs/specs/'`) cannot catch link rot from a
# directory move: relative targets like `../../decisions/` change meaning when the
# file holding them moves, and the string never appears in the file at all. This
# resolves link *targets* instead.
#
# Usage:
#   ./scripts/validate-links.sh            # fail on any broken link not in the allowlist
#   ./scripts/validate-links.sh --list     # print every broken link, exit 0 (for refreshing the allowlist)
#
# Allowlist: .linkcheck-allow — one `<file><TAB><target>` per line, `#` comments allowed.
# It exists so pre-existing breakage does not block unrelated work; entries should be
# deleted as they are fixed, never added to route around a new break.
#
# Skipped by design: absolute URLs, anchors, absolute paths, template placeholders, and
# anything inside a fenced code block or an inline code span (documentation samples are
# not navigation).

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"
ALLOW=".linkcheck-allow"

mapfile -t BROKEN < <(python3 - <<'PY'
import os, re, subprocess

files = subprocess.run(['git', 'ls-files', '*.md'],
                       capture_output=True, text=True).stdout.split()
link = re.compile(r'\[[^\]]*\]\(([^)#\s]+)(?:#[^)\s]*)?\)')
fence = re.compile(r'^\s*(```|~~~)')
# inline code spans hold illustrative links, not navigation — strip before matching
code_span = re.compile(r'(`+)(?:(?!\1).)*\1')

for f in files:
    d = os.path.dirname(f)
    try:
        lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        continue
    in_fence = False
    for line in lines:
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in link.finditer(code_span.sub('', line)):
            t = m.group(1)
            if t.startswith(('http://', 'https://', 'mailto:', 'tel:', '<', '/')):
                continue
            # template placeholders, not real paths
            if any(c in t for c in '<>*\\') or 'NNN' in t or 'YYYY' in t:
                continue
            if not os.path.exists(os.path.normpath(os.path.join(d, t))):
                print(f"{f}\t{t}")
PY
)

if [ "$MODE" = "--list" ]; then
    printf '%s\n' "${BROKEN[@]}"
    exit 0
fi

allowed() {
    [ -f "$ALLOW" ] || return 1
    grep -qxF "$1" <(grep -v '^\s*#' "$ALLOW" | grep -v '^\s*$')
}

fail=0
for entry in "${BROKEN[@]}"; do
    [ -n "$entry" ] || continue
    if ! allowed "$entry"; then
        printf 'BROKEN  %s\n' "$entry"
        fail=1
    fi
done

total=${#BROKEN[@]}
[ "$total" -eq 1 ] && [ -z "${BROKEN[0]}" ] && total=0
if [ "$fail" -eq 0 ]; then
    echo "==> All relative Markdown links resolve (${total} allowlisted)."
else
    echo
    echo "Broken relative links found. Fix the target, or — only for pre-existing"
    echo "breakage unrelated to your change — add the line to ${ALLOW}."
    exit 1
fi
