#!/usr/bin/env bash
# Single entry point for Kubernetes manifest validation (SPEC-007 FR-010).
#
# Runs the same steps locally and in CI, so "it validates" is a claim
# backed by a command anyone — human or agent — can reproduce:
#   1. check every Flux Kustomization that applies ${vars} declares postBuild
#   2. parse the PromQL inside every repo-authored VMRule
#   3. generate the schema catalog (XRDs + Envoy AI Gateway CRDs)
#   4. render the repo into a bundle (kustomize + envsubst + helm template)
#   5. gate the bundle: flux schema validate, then polaris audit
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Resolves FLUX_BIN / HELM_BIN / KUSTOMIZE_BIN and hard-fails on a too-old
# flux client or a missing schema plugin, instead of silently picking up
# whatever stale binary happens to be first on PATH.
# shellcheck source=./flux-schema/preflight.sh
source "${REPO_ROOT}/scripts/flux-schema/preflight.sh"

if ! command -v polaris >/dev/null 2>&1; then
  echo "error: polaris not found on PATH." >&2
  echo "       Fix: install Polaris v8.5.0 - https://github.com/FairwindsOps/polaris/releases/tag/8.5.0" >&2
  exit 1
fi

BUNDLE_DIR="${BUNDLE_DIR:-.bundle}"

# Runs FIRST and fails fast, because it is the one check the bundle cannot make.
# render-bundle.py substitutes its fixtures unconditionally, so a Kustomization
# missing postBuild renders correctly in the bundle and lands as literal
# `${var}` text on the cluster. Measured 2026-08-25; see the script's docstring.
echo "==> [1/5] Checking Flux variable substitution wiring"
python3 scripts/flux-schema/check-substitution.py

# Also runs before the render, and on source files rather than the bundle: a
# VMRule expression is opaque to both gates below — `flux schema validate`
# proves `expr` is a string in the right place, and polaris does not look at
# rules at all. See the script's header for why it reads committed VMRules
# instead of ${BUNDLE_DIR}, and which groups it skips.
echo "==> [2/5] Checking PromQL expressions in repo-authored VMRules"
./scripts/validate-vmrules.sh

echo "==> [3/5] Generating schema catalog"
./scripts/flux-schema/gen-catalog.sh > /dev/null

echo "==> [4/5] Rendering manifests into ${BUNDLE_DIR}/"
rm -rf "${BUNDLE_DIR}"
python3 scripts/flux-schema/render-bundle.py "${BUNDLE_DIR}"

echo "==> [5/5] Gate 1 — flux schema validate (structure + CEL)"
"${FLUX_BIN}" schema validate "${BUNDLE_DIR}" --config .fluxschema.yml

echo "==> [5/5] Gate 2 — polaris audit (workload best practices)"
polaris audit \
  --audit-path "${BUNDLE_DIR}" \
  --config .polaris.yaml \
  --set-exit-code-on-danger \
  --only-show-failed-tests

echo "==> All gates passed"
