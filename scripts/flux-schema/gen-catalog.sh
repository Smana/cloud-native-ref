#!/usr/bin/env bash
# Build the local JSON-Schema catalog consumed by `flux schema validate`.
#
# Two sources (SPEC-007 FR-002):
#   1. The repo's own Crossplane XRDs  -> cloud.ogenki.io/*
#   2. Envoy AI Gateway CRDs           -> aigateway.envoyproxy.io/*
#      (absent from the hosted ecosystem catalog)
#
# The catalog is generated, never committed, so it cannot drift from the XRDs.
#
# Built into a scratch directory and only swapped onto ${SCHEMA_DIR} once
# verified complete: `flux schema extract crd` exits 0 and writes 0 files
# when given an input with no CRDs in it (verified against flux 2.9.2), so
# a chart that stops shipping CRDs in its rendered output (or a helm
# template call missing --include-crds) would otherwise silently drop a
# whole schema group while the build still reports success. A failed or
# incomplete run must never leave a half-built (or emptied) catalog on
# disk for `flux schema validate` to trust (SPEC-007 review I1/I2).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Resolves FLUX_BIN / HELM_BIN / KUSTOMIZE_BIN and hard-fails on a
# too-old flux client or a missing schema plugin, instead of silently
# picking up whatever stale binary happens to be first on PATH.
# shellcheck source=./preflight.sh
source "${REPO_ROOT}/scripts/flux-schema/preflight.sh"

SCHEMA_DIR="${SCHEMA_DIR:-.schemas}"

# Single source of truth: the same OCIRepository pin Flux uses to install the
# CRDs on the cluster. Renovate bumps that file; this script follows it.
# Portable (no GNU-only `grep -oP`): sed -E is extended-regex on both GNU
# and BSD/macOS sed. The trailing `|| true` matters: under `set -e` +
# `pipefail`, a failing sed/grep would otherwise abort the script *before*
# the "could not read the version" guard below ever runs.
AI_GATEWAY_SOURCE="flux/sources/ocirepo-envoy-ai-gateway-crds.yaml"
AI_GATEWAY_CHART="oci://docker.io/envoyproxy/ai-gateway-crds-helm"
AI_GATEWAY_VERSION="$(sed -nE 's/^[[:space:]]*tag:[[:space:]]*"?([0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "${AI_GATEWAY_SOURCE}" | head -n1 || true)"

if [[ -z "${AI_GATEWAY_VERSION}" ]]; then
  echo "error: could not read the AI Gateway CRD chart version from ${AI_GATEWAY_SOURCE}" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

build_dir="${tmp}/schemas"
mkdir -p "${build_dir}"

echo "==> Converting Crossplane XRDs to CRDs"
python3 scripts/flux-schema/xrd-to-crd.py \
  infrastructure/base/crossplane/configuration/*-definition.yaml \
  > "${tmp}/xrd-crds.yaml"

echo "==> Rendering Envoy AI Gateway CRDs (chart ${AI_GATEWAY_VERSION})"
# --include-crds: Helm skips a chart's crds/ directory by default. Without
# this flag a chart that packages its CRDs there (rather than as regular
# templates) renders zero CRDs, and helm still exits 0.
"${HELM_BIN}" template aigw-crds "${AI_GATEWAY_CHART}" --version "${AI_GATEWAY_VERSION}" --include-crds \
  > "${tmp}/aigateway-crds.yaml"

echo "==> Extracting JSON Schemas into ${build_dir}/"
"${FLUX_BIN}" schema extract crd "${tmp}/xrd-crds.yaml" -d "${build_dir}"
"${FLUX_BIN}" schema extract crd "${tmp}/aigateway-crds.yaml" -d "${build_dir}"

echo "==> Verifying the catalog is complete"
for kind in app sqlinstance inferenceservice epi; do
  schema_file="${build_dir}/cloud.ogenki.io/${kind}_v1alpha1.json"
  if [[ ! -s "${schema_file}" ]]; then
    echo "error: catalog build produced no (or an empty) schema at cloud.ogenki.io/${kind}_v1alpha1.json" >&2
    exit 1
  fi
done

if ! compgen -G "${build_dir}/aigateway.envoyproxy.io/*.json" >/dev/null; then
  echo "error: catalog build produced zero aigateway.envoyproxy.io schemas (chart ${AI_GATEWAY_VERSION} rendered no CRDs?)" >&2
  exit 1
fi

# Atomic swap: the on-disk catalog is only ever replaced by a build that's
# already been proven complete above.
rm -rf "${SCHEMA_DIR}"
mv "${build_dir}" "${SCHEMA_DIR}"

find "${SCHEMA_DIR}" -name '*.json' | sort
