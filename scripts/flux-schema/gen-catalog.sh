#!/usr/bin/env bash
# Build the local JSON-Schema catalog consumed by `flux schema validate`.
#
# Three sources (SPEC-007 FR-002):
#   1. The repo's own Crossplane XRDs  -> cloud.ogenki.io/*
#   2. Envoy AI Gateway CRDs           -> aigateway.envoyproxy.io/*
#      (absent from the hosted ecosystem catalog)
#   3. Karpenter CRDs                  -> karpenter.k8s.aws/*, karpenter.sh/*
#      (PRESENT in the hosted ecosystem catalog but STALE: it pins an older
#      provider release that predates fields we use — e.g. EC2NodeClass
#      amiSelectorTerms[].ssmParameter, required for the Bottlerocket NVIDIA
#      variant. Generating them here from the same OCI pin Flux installs makes
#      the local catalog win over the stale ecosystem entry, matching the
#      deployed CRD exactly.)
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
# BOTH the chart URL and its version come from the OCIRepository Flux uses to
# install these CRDs, so the catalog can never drift from what is applied
# (the URL was previously hardcoded and would silently diverge on a registry
# move). The tag regex accepts an optional leading `v` (v1.2.3 is a valid tag).
AI_GATEWAY_CHART="$(sed -nE 's#^[[:space:]]*url:[[:space:]]*"?(oci://[^"[:space:]]+)"?[[:space:]]*$#\1#p' "${AI_GATEWAY_SOURCE}" | head -n1 || true)"
AI_GATEWAY_VERSION="$(sed -nE 's/^[[:space:]]*tag:[[:space:]]*"?(v?[0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "${AI_GATEWAY_SOURCE}" | head -n1 || true)"

if [[ -z "${AI_GATEWAY_CHART}" ]]; then
  echo "error: could not read the AI Gateway CRD chart url from ${AI_GATEWAY_SOURCE}" >&2
  exit 1
fi
if [[ -z "${AI_GATEWAY_VERSION}" ]]; then
  echo "error: could not read the AI Gateway CRD chart version from ${AI_GATEWAY_SOURCE}" >&2
  exit 1
fi

# Same single-source-of-truth approach for Karpenter: chart URL + version come
# from the OCIRepository Flux installs. NOTE the version key differs from the AI
# Gateway source — Karpenter's OCIRepository pins `ref.semver:`, not `ref.tag:`
# — so this regex reads `semver:` (a bare version or a range like ">=1.0.0"; the
# leading token is enough for `helm template --version`).
KARPENTER_SOURCE="flux/sources/ocirepo-karpenter.yaml"
KARPENTER_CHART="$(sed -nE 's#^[[:space:]]*url:[[:space:]]*"?(oci://[^"[:space:]]+)"?[[:space:]]*$#\1#p' "${KARPENTER_SOURCE}" | head -n1 || true)"
KARPENTER_VERSION="$(sed -nE 's/^[[:space:]]*semver:[[:space:]]*"?(v?[0-9][^"[:space:]]*)"?[[:space:]]*$/\1/p' "${KARPENTER_SOURCE}" | head -n1 || true)"

if [[ -z "${KARPENTER_CHART}" ]]; then
  echo "error: could not read the Karpenter chart url from ${KARPENTER_SOURCE}" >&2
  exit 1
fi
if [[ -z "${KARPENTER_VERSION}" ]]; then
  echo "error: could not read the Karpenter chart version from ${KARPENTER_SOURCE}" >&2
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

echo "==> Rendering Karpenter CRDs (chart ${KARPENTER_VERSION})"
# The pinned OCIRepository is the FULL karpenter chart (controller + CRDs), not
# a dedicated CRD chart, so `helm template` also renders the controller
# templates — and the Deployment template hard-fails without settings.clusterName
# ("Chart cannot be installed without a valid settings.clusterName!"). The value
# is render-only: `flux schema extract crd` below picks out ONLY the CRDs, so
# this throwaway name never reaches the catalog.
"${HELM_BIN}" template karpenter "${KARPENTER_CHART}" --version "${KARPENTER_VERSION}" --include-crds \
  --set settings.clusterName=catalog \
  > "${tmp}/karpenter-crds.yaml"

echo "==> Extracting JSON Schemas into ${build_dir}/"
"${FLUX_BIN}" schema extract crd "${tmp}/xrd-crds.yaml" -d "${build_dir}"
"${FLUX_BIN}" schema extract crd "${tmp}/aigateway-crds.yaml" -d "${build_dir}"
"${FLUX_BIN}" schema extract crd "${tmp}/karpenter-crds.yaml" -d "${build_dir}"

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

# EC2NodeClass is the schema this source exists to fix (the stale ecosystem
# entry lacks ssmParameter); assert it specifically, not just "some karpenter
# schema landed".
if [[ ! -s "${build_dir}/karpenter.k8s.aws/ec2nodeclass_v1.json" ]]; then
  echo "error: catalog build produced no karpenter.k8s.aws/ec2nodeclass_v1.json (chart ${KARPENTER_VERSION} rendered no CRDs?)" >&2
  exit 1
fi

# Atomic swap: the on-disk catalog is only ever replaced by a build that's
# already been proven complete above.
rm -rf "${SCHEMA_DIR}"
mv "${build_dir}" "${SCHEMA_DIR}"

find "${SCHEMA_DIR}" -name '*.json' | sort
