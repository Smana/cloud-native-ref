#!/usr/bin/env bash
# Single entry point for Kubernetes manifest validation (SPEC-007 FR-010).
#
# Runs the same three steps locally and in CI, so "it validates" is a claim
# backed by a command anyone — human or agent — can reproduce:
#   1. generate the schema catalog (XRDs + Envoy AI Gateway CRDs)
#   2. render the repo into a bundle (kustomize + envsubst + helm template)
#   3. gate the bundle: flux schema validate, then polaris audit
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

echo "==> [1/3] Generating schema catalog"
./scripts/flux-schema/gen-catalog.sh > /dev/null

echo "==> [2/3] Rendering manifests into ${BUNDLE_DIR}/"
rm -rf "${BUNDLE_DIR}"
python3 scripts/flux-schema/render-bundle.py "${BUNDLE_DIR}"

echo "==> [3/3] Gate 1 — flux schema validate (structure + CEL)"
"${FLUX_BIN}" schema validate "${BUNDLE_DIR}" --config .fluxschema.yml

echo "==> [3/3] Gate 2 — polaris audit (workload best practices)"
polaris audit \
  --audit-path "${BUNDLE_DIR}" \
  --config .polaris.yaml \
  --set-exit-code-on-danger \
  --only-show-failed-tests

echo "==> All gates passed"
