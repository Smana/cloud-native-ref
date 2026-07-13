#!/usr/bin/env bash
# Build the local JSON-Schema catalog consumed by `flux schema validate`.
#
# Two sources (SPEC-007 FR-002):
#   1. The repo's own Crossplane XRDs  -> cloud.ogenki.io/*
#   2. Envoy AI Gateway CRDs           -> aigateway.envoyproxy.io/*
#      (absent from the hosted ecosystem catalog)
#
# The catalog is generated, never committed, so it cannot drift from the XRDs.
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
AI_GATEWAY_SOURCE="flux/sources/ocirepo-envoy-ai-gateway-crds.yaml"
AI_GATEWAY_CHART="oci://docker.io/envoyproxy/ai-gateway-crds-helm"
AI_GATEWAY_VERSION="$(grep -oP 'tag:\s*"?\K[0-9][^"]*' "${AI_GATEWAY_SOURCE}" | tr -d '"')"

if [[ -z "${AI_GATEWAY_VERSION}" ]]; then
  echo "error: could not read the AI Gateway CRD chart version from ${AI_GATEWAY_SOURCE}" >&2
  exit 1
fi

rm -rf "${SCHEMA_DIR}"
mkdir -p "${SCHEMA_DIR}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "==> Converting Crossplane XRDs to CRDs"
python3 scripts/flux-schema/xrd-to-crd.py \
  infrastructure/base/crossplane/configuration/*-definition.yaml \
  > "${tmp}/xrd-crds.yaml"

echo "==> Rendering Envoy AI Gateway CRDs (chart ${AI_GATEWAY_VERSION})"
"${HELM_BIN}" template aigw-crds "${AI_GATEWAY_CHART}" --version "${AI_GATEWAY_VERSION}" \
  > "${tmp}/aigateway-crds.yaml"

echo "==> Extracting JSON Schemas into ${SCHEMA_DIR}/"
"${FLUX_BIN}" schema extract crd "${tmp}/xrd-crds.yaml" -d "${SCHEMA_DIR}"
"${FLUX_BIN}" schema extract crd "${tmp}/aigateway-crds.yaml" -d "${SCHEMA_DIR}"

find "${SCHEMA_DIR}" -name '*.json' | sort
