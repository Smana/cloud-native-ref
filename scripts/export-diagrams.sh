#!/usr/bin/env bash
#
# export-diagrams.sh — regenerate every diagram export from its .drawio source.
#
# Sources live in docs/architecture/ (one topic per file, kebab-case, ogenki
# preset). Exports are written where each consumer needs them:
#   - website/assets/diagrams/         for docs pages
#   - website/static/images/diagrams/  for the landing page (no asset pipeline)
#   - docs/architecture/img/           PNG, only where GitHub also renders it
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
ASSETS="website/assets/diagrams"
STATIC="website/static/images/diagrams"
mkdir -p "$ASSETS" "$STATIC"

# Task 16 appends the six new domain diagrams here.
SINGLE_PAGE=()

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
    drawio "${SVGOPTS[@]}" -o "$ASSETS/$name.svg" "$SRC/$name.drawio"
done

# platform-overview is embedded in both the site and the GitHub README, so it
# needs both formats and lands in static/ for the home layout.
echo "==> platform-overview (svg + png)"
drawio "${SVGOPTS[@]}" -o "$STATIC/platform-overview.svg" "$SRC/platform-overview.drawio"
drawio -x -f png -s 2 -b 10 -o "$SRC/img/platform-overview.png" "$SRC/platform-overview.drawio"

# --page-index is 1-based in this drawio CLI (`-p, --page-index <pageIndex>
# selects a specific page (1-based)`), despite looking like it should be
# 0-based. Looping 0 1 2 here silently exported page 1 twice and dropped page
# 3 (page-index=0 falls back to "not specified" -> first page). Loop 1 2 3
# instead, with the file suffix matching page-index directly.
for i in 1 2 3; do
    echo "==> llm-platform page $i"
    drawio "${SVGOPTS[@]}" --page-index "$i" \
        -o "$ASSETS/llm-platform-$i.svg" "$SRC/llm-platform.drawio"
done

echo
echo "==> Size check (budget: 500 KB per SVG export)"
find "$ASSETS" "$STATIC" -name '*.svg' -size +500k -printf '    OVER BUDGET: %p (%s bytes)\n' | tee /tmp/oversize
[ ! -s /tmp/oversize ] || { echo "Reduce embedded raster logos or their resolution."; exit 1; }
echo "    all exports within budget"
