#!/usr/bin/env bash
#
# export-diagrams.sh — regenerate every diagram export from its .drawio source.
#
# Sources live in docs/architecture/ (one topic per file, kebab-case, ogenki
# preset). Exports are written where each consumer needs them:
#   - website/static/images/diagrams/  every SVG the site embeds
#   - docs/architecture/img/           PNG, only where GitHub also renders it
#
# static/, not assets/. Hugo publishes static/ verbatim; assets/ is the input to
# the asset pipeline and is only reachable from a template through resources.Get.
# This site has no such template, so an SVG written to website/assets/diagrams/
# is never served and every <img> pointing at it 404s.
#
# SVG is the site format. The PNG-only rule recorded in docs/architecture/README.md
# exists because GitHub's sanitizer strips <foreignObject> text from drawio SVG,
# which does not apply to a Hugo site.
#
# Requires the draw.io desktop app on PATH.

set -euo pipefail
cd "$(dirname "$0")/.."

command -v drawio >/dev/null || { echo "drawio not on PATH — install the desktop app"; exit 1; }

SRC="docs/architecture"
OUT="website/static/images/diagrams"
mkdir -p "$OUT"

# One SVG per source, one section of the site each opens.
SINGLE_PAGE=(
    bootstrap-stages
    flux-dependency-tree
    ci-pipeline
    request-path
    secrets-and-pki
    app-claim-expansion
    observability-flow
    authentication-chain
)

# --embed-svg-fonts false is load-bearing, not a micro-optimisation. drawio
# embeds the full font as base64 by default: platform-overview exports at
# 1.29 MB with fonts and 155 KB without — the fonts are 1.14 MB of it, while
# every logo in the diagram together is only 64 KB. That difference is the
# whole 500 KB budget, and it also clears pre-commit's 1000 KB ceiling.
#
# Nothing is lost. The ogenki preset sets fontFamily: Helvetica, a web-safe
# stack every browser resolves locally, so embedding a font to render
# "Helvetica" buys nothing. Labels are unaffected: they live in <foreignObject>
# elements, which is also why these SVGs must not be embedded in the GitHub
# README — GitHub's sanitizer strips foreignObject and the diagram would render
# with no text at all. That is what the PNG below is for.
SVGOPTS=(-x -f svg -b 10 --embed-svg-fonts false)

for name in "${SINGLE_PAGE[@]}"; do
    echo "==> $name.svg"
    drawio "${SVGOPTS[@]}" -o "$OUT/$name.svg" "$SRC/$name.drawio"
done

# platform-overview is embedded in both the site and the GitHub README, so it
# needs both formats — SVG for the site, PNG because GitHub's sanitizer strips
# the <foreignObject> elements drawio puts every label in.
echo "==> platform-overview (svg + png)"
drawio "${SVGOPTS[@]}" -o "$OUT/platform-overview.svg" "$SRC/platform-overview.drawio"
drawio -x -f png -s 2 -b 10 -o "$SRC/img/platform-overview.png" "$SRC/platform-overview.drawio"

# --page-index is 1-based in this drawio CLI (`-p, --page-index <pageIndex>
# selects a specific page (1-based)`), despite looking like it should be
# 0-based. Looping 0 1 2 here silently exported page 1 twice and dropped page
# 3 (page-index=0 falls back to "not specified" -> first page). Loop 1 2 3
# instead, with the file suffix matching page-index directly.
for i in 1 2 3; do
    echo "==> llm-platform page $i"
    drawio "${SVGOPTS[@]}" --page-index "$i" \
        -o "$OUT/llm-platform-$i.svg" "$SRC/llm-platform.drawio"
done

# drawio ends its SVG output without a trailing newline; pre-commit's
# end-of-file-fixer adds one. Without this, every export leaves the tree dirty
# by exactly one byte per file and the script is never idempotent.
# Portable append (BSD sed reads `-i -e` as backup-suffix "-e" and litters
# *.svg-e files): only add the newline when the last byte is not already one.
find "$OUT" -name '*.svg' -exec sh -c '
    for f; do [ -n "$(tail -c1 "$f")" ] && printf "\n" >> "$f"; done; :
' _ {} +

echo
echo "==> Size check (budget: 500 KB per SVG export)"
# -exec ls, not -printf: BSD find (macOS) has no -printf, and this script runs
# on contributor laptops as well as CI.
find "$OUT" -name '*.svg' -size +500k -exec sh -c 'printf "    OVER BUDGET: %s (%s bytes)\n" "$1" "$(wc -c < "$1")"' _ {} \; | tee "${TMPDIR:-/tmp}/oversize"
[ ! -s "${TMPDIR:-/tmp}/oversize" ] || { echo "Reduce embedded raster logos or their resolution."; exit 1; }
echo "    all exports within budget"
