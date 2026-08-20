#!/usr/bin/env bash
#
# verify-doc-paths.sh — assert that every repository path named in the docs site
# still exists.
#
# scripts/validate-links.sh resolves Markdown *links*. It cannot see the far more
# common failure in this repository's prose: a backticked path in running text
# ("configured in `opentofu/eks/configure/locals.tf`") that silently stops being
# true after a refactor. This closes that gap, and is what makes the design's
# "verify-on-migrate" rule mechanical rather than a promise.
#
# Only strings that look like repository paths are checked: they contain a `/`
# and start with a known top-level directory. Everything else in backticks —
# commands, field names, prose — is ignored.
#
# NOTE: this walks `git ls-files`, so it only sees TRACKED files. Run it after
# `git add`, or a brand-new page passes without ever being checked.
#
# Usage:
#   ./scripts/verify-doc-paths.sh          # fail on the first missing path
#   ./scripts/verify-doc-paths.sh --list   # print every missing path, exit 0

set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-check}"

mapfile -t MISSING < <(python3 - <<'PY'
import os, re, subprocess

TOP = ('apps/', 'clusters/', 'container-images/', 'crds/', 'docs/', 'flux/',
       'infrastructure/', 'namespaces/', 'observability/', 'opentofu/',
       'scripts/', 'security/', 'tooling/', 'website/', '.github/', '.claude/')

files = subprocess.run(['git', 'ls-files', 'website/content/*.md'],
                       capture_output=True, text=True).stdout.split()
# Backticked spans only. Prose mentions without backticks are not claims about
# the tree; treating them as such produces noise nobody acts on.
span = re.compile(r'`([^`\n]+)`')

for f in files:
    with open(f, encoding='utf-8') as fh:
        for n, line in enumerate(fh, 1):
            for raw in span.findall(line):
                # Strip a trailing line-range suffix such as ":123-145".
                p = re.sub(r':\d+(-\d+)?$', '', raw.strip())
                if not p.startswith(TOP):
                    continue
                # A glob or a placeholder is not a claim about a concrete file.
                if any(c in p for c in '*?<>${}'):
                    continue
                if not os.path.exists(p):
                    print(f'{f}:{n}\t{p}')
PY
)

if [ "$MODE" = "--list" ]; then
    printf '%s\n' "${MISSING[@]}"
    exit 0
fi

if [ ${#MISSING[@]} -gt 0 ] && [ -n "${MISSING[0]}" ]; then
    echo "==> Documentation names paths that do not exist:"
    printf '    %s\n' "${MISSING[@]}"
    echo
    echo "Fix the path, or drop the reference. Do not add an allowlist."
    exit 1
fi

echo "==> Every repository path named in the docs site exists."
