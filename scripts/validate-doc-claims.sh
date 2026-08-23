#!/usr/bin/env bash
#
# validate-doc-claims.sh — check that documentation still agrees with configuration.
#
# The other gates in this repository check structure: links resolve, schemas
# validate, the site builds. None of them can tell whether a sentence is true.
# On 2026-08-21/22 four pages were found asserting things the manifests
# contradicted — a five-node OpenBao cluster that variables.tfvars sets to one
# node, a single VMAlert where two exist, an IP count presented as a pod
# ceiling, a `values: {}` attributed to both Kyverno releases when only one has
# it. Every gate was green throughout.
#
# This closes that class for claims worth pinning. `.doc-claims.yaml` names a
# source of truth, a value to read from it, and the pages whose prose depends
# on that value. The check is bidirectional: it fails when config moves away
# from the docs, and when docs move away from config.
#
# It is deliberately not clever. It cannot verify prose in general and does not
# try; it verifies the specific claims someone chose to pin. Adding one is a
# few lines of YAML.
#
# Usage:
#   ./scripts/validate-doc-claims.sh          # fail on any violated claim
#   ./scripts/validate-doc-claims.sh --list   # print every claim and its current value

set -euo pipefail
cd "$(dirname "$0")/.."

CLAIMS_FILE=".doc-claims.yaml"
MODE="${1:-check}"

if [ ! -f "$CLAIMS_FILE" ]; then
  echo "error: $CLAIMS_FILE not found" >&2
  exit 2
fi

if ! python3 -c "import yaml" 2>/dev/null; then
  echo "error: PyYAML not installed." >&2
  echo "       Fix: python3 -m pip install pyyaml" >&2
  exit 2
fi

python3 - "$CLAIMS_FILE" "$MODE" <<'PY'
import os
import re
import sys

import yaml

claims_file, mode = sys.argv[1], sys.argv[2]
listing = mode == "--list"

with open(claims_file, encoding="utf-8") as fh:
    claims = (yaml.safe_load(fh) or {}).get("claims") or []

if not claims:
    print("error: no claims defined in %s" % claims_file, file=sys.stderr)
    sys.exit(2)


def wrap(text, width=72, indent="    "):
    """Reflow `why` text so failure output stays readable in a CI log."""
    words = " ".join((text or "").split())
    if not words:
        return ""
    lines, cur = [], ""
    for w in words.split(" "):
        if len(cur) + len(w) + 1 > width:
            lines.append(indent + cur)
            cur = w
        else:
            cur = w if not cur else cur + " " + w
    if cur:
        lines.append(indent + cur)
    return "\n".join(lines)


failures = []
checked = 0

for claim in claims:
    cid = claim.get("id", "<unnamed>")
    source = claim.get("source") or {}
    src_file = source.get("file")
    pattern = source.get("pattern")

    if not src_file:
        failures.append((cid, claim, "claim has no source.file"))
        continue

    if not os.path.exists(src_file):
        # The source of truth moved or was deleted. That is exactly when docs
        # rot, so this is a failure rather than a skip.
        failures.append(
            (cid, claim, "source of truth is missing: %s" % src_file)
        )
        continue

    value = None
    if pattern:
        text = open(src_file, encoding="utf-8", errors="replace").read()
        m = re.search(pattern, text, re.M)
        if not m:
            failures.append(
                (
                    cid,
                    claim,
                    "pattern %r matched nothing in %s — the file changed shape, "
                    "so the claim can no longer be verified" % (pattern, src_file),
                )
            )
            continue
        value = m.group(1)

    if listing:
        print("%-28s %-52s %s" % (cid, src_file, value if value else "(exists)"))
        continue

    for entry in claim.get("pages") or []:
        # A page is either a bare path (uses the claim's must_contain) or a
        # mapping that overrides it. The override exists because a shared
        # pattern is often too loose: pages that deliberately document BOTH a
        # committed and an alternative value match `mode = "{value}"` whichever
        # value is read, so the check silently passes on real drift. Anchoring
        # on each page's own phrasing is what makes it bite.
        if isinstance(entry, dict):
            page = entry.get("path")
            must = entry.get("must_contain", claim.get("must_contain"))
            banned_extra = entry.get("must_not_contain") or []
        else:
            page, must, banned_extra = entry, claim.get("must_contain"), []

        checked += 1
        if not page:
            failures.append((cid, claim, "page entry has no path"))
            continue
        if not os.path.exists(page):
            failures.append((cid, claim, "page is missing: %s" % page))
            continue
        prose = open(page, encoding="utf-8", errors="replace").read()

        if must:
            needle = must.replace("{value}", re.escape(value or ""))
            if not re.search(needle, prose):
                failures.append(
                    (
                        cid,
                        claim,
                        "%s does not state the current value.\n"
                        "    %s says %s\n"
                        "    the page must match: %s"
                        % (page, src_file, value, needle),
                    )
                )

        for banned in list(claim.get("must_not_contain") or []) + list(banned_extra):
            needle = banned.replace("{value}", re.escape(value or ""))
            if re.search(needle, prose):
                failures.append(
                    (cid, claim, "%s still matches %r" % (page, needle))
                )

if listing:
    sys.exit(0)

if failures:
    print()
    for cid, claim, detail in failures:
        print("BROKEN CLAIM  %s" % cid)
        print("    %s" % detail)
        why = wrap(claim.get("why"))
        if why:
            print("  why this is pinned:")
            print(why)
        print()
    print(
        "%d documentation claim(s) no longer match the repository.\n"
        "Fix the page, or — if the configuration deliberately changed — update\n"
        "the page and the claim together in %s." % (len(failures), claims_file)
    )
    sys.exit(1)

print(
    "==> All %d documentation claims match the repository (%d page checks)."
    % (len(claims), checked)
)
PY
