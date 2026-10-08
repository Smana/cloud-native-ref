#!/usr/bin/env bash
# Print the path of the Crossplane XRD CRDs of the pinned crossplane-configuration
# pre-release, for XRD_CRDS_FILE (gen-catalog.sh). A release pin prints nothing:
# gen-catalog.sh fetches the release asset itself. A pre-release (v<x.y.z>-pr<N>.<sha>)
# has no release; its PR CI publishes the same file as an OCI artifact (SP2 ruling P40).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${XPKG_SOURCE:-$ROOT/infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml}"
# The expression gen-catalog.sh reads XPKG_VERSION with.
ver="$(sed -nE 's#^[[:space:]]*package:[[:space:]]*"?[^":[:space:]]+:(v?[0-9][^"[:space:]]*)"?[[:space:]]*$#\1#p' "$SRC" | head -n1)"
case "$ver" in
  *-pr*) ;;
  *) exit 0 ;;
esac
out="${XRD_CRDS_DIR:-$(mktemp -d)}"
flux pull artifact "oci://ghcr.io/smana/crossplane-configuration-xrd-crds:${ver}" --output "$out" >&2
[ -s "$out/xrd-crds.yaml" ] || { echo "error: no xrd-crds.yaml in the artifact of ${ver}" >&2; exit 1; }
echo "$out/xrd-crds.yaml"
