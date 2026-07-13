#!/usr/bin/env bash
# Toolchain preflight guard for the SPEC-007 flux-schema tooling.
#
# A stale `flux`/`helm`/`kustomize` earlier in $PATH must not be picked up
# silently: it can produce an empty or wrong-shape schema catalog while
# exiting 0, which is exactly the "unknown kind silently skipped" failure
# class this spec exists to remove (FR-005).
#
# Resolution precedence, per tool: explicit env var override > mise
# (scoped to this repo's mise.toml) > bare PATH lookup. Exports FLUX_BIN,
# HELM_BIN, KUSTOMIZE_BIN; callers must invoke "${FLUX_BIN}" / "${HELM_BIN}"
# / "${KUSTOMIZE_BIN}" instead of the bare command names.
#
# Must be SOURCED, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
set -euo pipefail

_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PREFLIGHT_REPO_ROOT="$(cd "${_PREFLIGHT_DIR}/../.." && pwd)"

_flux_schema_resolve_bin() {
  local override="$1" tool="$2" resolved=""

  if [[ -n "${override}" ]]; then
    printf '%s\n' "${override}"
    return 0
  fi

  if command -v mise >/dev/null 2>&1 && [[ -f "${_PREFLIGHT_REPO_ROOT}/mise.toml" ]]; then
    if resolved="$(mise which -C "${_PREFLIGHT_REPO_ROOT}" "${tool}" 2>/dev/null)" && [[ -n "${resolved}" ]]; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  fi

  if resolved="$(command -v "${tool}" 2>/dev/null)"; then
    printf '%s\n' "${resolved}"
    return 0
  fi

  return 1
}

FLUX_BIN="$(_flux_schema_resolve_bin "${FLUX_BIN:-}" flux || true)"
HELM_BIN="$(_flux_schema_resolve_bin "${HELM_BIN:-}" helm || true)"
KUSTOMIZE_BIN="$(_flux_schema_resolve_bin "${KUSTOMIZE_BIN:-}" kustomize || true)"
export FLUX_BIN HELM_BIN KUSTOMIZE_BIN

if [[ -z "${HELM_BIN}" ]]; then
  echo "error: helm not found (checked \$HELM_BIN, mise, PATH)." >&2
  echo "       required: helm v3.12+. Fix: mise install helm  (or set HELM_BIN)" >&2
  exit 1
fi

if [[ -z "${KUSTOMIZE_BIN}" ]]; then
  echo "error: kustomize not found (checked \$KUSTOMIZE_BIN, mise, PATH)." >&2
  echo "       Fix: mise install kustomize  (or set KUSTOMIZE_BIN)" >&2
  exit 1
fi

if [[ -z "${FLUX_BIN}" ]]; then
  echo "error: flux not found (checked \$FLUX_BIN, mise, PATH)." >&2
  echo "       required: flux client v2.9.0+. Fix: mise install flux2 2.9.2  (or set FLUX_BIN)" >&2
  exit 1
fi

_flux_schema_client_version="$("${FLUX_BIN}" version --client 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ -z "${_flux_schema_client_version}" ]]; then
  echo "error: could not determine the flux client version from '${FLUX_BIN} version --client'." >&2
  exit 1
fi

_flux_schema_major="${_flux_schema_client_version%%.*}"
_flux_schema_minor_patch="${_flux_schema_client_version#*.}"
_flux_schema_minor="${_flux_schema_minor_patch%%.*}"

if ((_flux_schema_major < 2 || (_flux_schema_major == 2 && _flux_schema_minor < 9))); then
  echo "error: flux client at ${FLUX_BIN} is v${_flux_schema_client_version}; SPEC-007 requires >= v2.9.0 (needs 'flux plugin')." >&2
  echo "       Fix: mise install flux2 2.9.2  (or set FLUX_BIN to a >=2.9 binary)" >&2
  exit 1
fi

if ! "${FLUX_BIN}" plugin list 2>/dev/null | grep -qE '^schema[[:space:]]'; then
  echo "error: the flux 'schema' plugin is not installed for ${FLUX_BIN}." >&2
  echo "       Fix: flux plugin install schema" >&2
  exit 1
fi

unset -v _flux_schema_client_version _flux_schema_major _flux_schema_minor_patch _flux_schema_minor
