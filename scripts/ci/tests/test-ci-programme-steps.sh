#!/usr/bin/env bash
# requires: grep
#
# The programme's CI steps that main's ci.yaml does not have yet. A main merge whose
# ci.yaml conflict is resolved to main's version drops them without a conflict on the
# lines themselves, and nothing else notices: #2233 removed both from
# feat/factory-runlore that way. Each must stay a live step that runs its script.
# The patterns match the workflow's literal text, $f and $GITHUB_ENV included.
# shellcheck disable=SC2016
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
ci=.github/workflows/ci.yaml
fail=0
check() {
  grep -qE -- "$2" "$ci" || { printf 'FAIL %s: no step in %s matches %s\n' "$1" "$ci" "$2"; fail=1; }
}
check "Merge-gate invariants" '^[[:space:]]+run: \./scripts/ci/check-policy-gate-coverage\.sh && \./scripts/ci/check-workflow-secrets\.sh$'
check "pre-release XRD CRDs" '^[[:space:]]+f="\$\(\./scripts/ci/fetch-xrd-crds\.sh\)"$'
check "XRD_CRDS_FILE export" '^[[:space:]]+\[ -z "\$f" \] \|\| echo "XRD_CRDS_FILE=\$f" >> "\$GITHUB_ENV"$'
[ "$fail" -eq 0 ] && echo "PASS"
exit "$fail"
