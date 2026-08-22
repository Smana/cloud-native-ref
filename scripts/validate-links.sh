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
#
# `website/content/` is Hugo's tree and gets a DIFFERENT check, not no check. Its
# internal links are `relref` shortcodes this regex cannot resolve, so the resolver
# below skips it — but `refLinksErrorLevel: ERROR` governs only `ref`/`relref`, and
# a raw Markdown link bypasses it silently.
#
# The check that fits: Hugo rewrites a relative `.md` link to the target page's
# permalink BY NAME, so an in-tree relative link works even when its path is wrong
# (`../platform-constitution.md` from decisions/ still renders as
# /docs/reference/platform-constitution/, verified against built HTML). What it
# cannot rewrite is a target that is not a page at all — `../superpowers/specs/x.md`
# ships verbatim into the href and 404s. So inside this tree we assert exactly one
# thing: no relative link may resolve outside `website/content/`.

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"
ALLOW=".linkcheck-allow"

mapfile -t BROKEN < <(python3 - <<'PY'
import os, re, subprocess

files = subprocess.run(['git', 'ls-files', '*.md'],
                       capture_output=True, text=True).stdout.split()
# Two trees, two models. Outside website/content, links are file-relative and
# get resolved against the filesystem. Inside it, Hugo resolves a relative `.md`
# link to the target page's permalink by name — so an in-tree relative link
# works even with a wrong path, and flagging it would be a false positive. What
# Hugo cannot resolve is a target that is not a page: those it emits verbatim.
hugo_files = [f for f in files if f.startswith('website/content/')]
files = [f for f in files if not f.startswith('website/content/')]
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

# Every page Hugo can resolve a relative .md link to, keyed by basename —
# because that is what Hugo matches on, not the path.
#
# A page is not necessarily a file under website/content: `module.mounts` in
# hugo.yaml publishes files from elsewhere in the repo into the content tree
# (the platform constitution is mounted rather than moved, so its 50 inbound
# repository references keep working). Read the mount targets rather than
# hardcoding them, or this check invents broken links for real pages.
pages = {os.path.basename(f) for f in hugo_files}
try:
    cfg = open('website/hugo.yaml', encoding='utf-8').read()
except OSError:
    cfg = ''
for tgt in re.findall(r'^\s*target:\s*(\S+\.md)\s*$', cfg, re.M):
    pages.add(os.path.basename(tgt))

for f in hugo_files:
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
            if not t.startswith(('../', './')):
                continue
            if os.path.basename(t) not in pages:
                print(f"{f}\t{t} (no page with that name — Hugo emits the raw "
                      f"path and it 404s; use an absolute GitHub URL)")
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
