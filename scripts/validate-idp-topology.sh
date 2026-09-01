#!/usr/bin/env bash
#
# Assert that exactly one cloud hosts the identity provider, and that it is the
# cloud named by `primary_cloud` in opentofu/config.tm.hcl.
#
# WHY THIS EXISTS
#
# ADR-0027 makes ZITADEL a primary-cloud singleton: it relocates to whichever
# cloud is primary, and two clouds each running one is ruled out -- two user
# directories mean a grant says nothing without knowing which directory issued
# it. Placement is set in two places that cannot enforce each other:
#
#   1. `deploy_identity_provider` (OpenTofu)  -- derived from primary_cloud
#   2. `spec.suspend` (Flux Kustomization)    -- committed Git state
#
# Flux never sees Terramate globals, so gate 2 cannot be derived and is checked
# here instead. The forbidden state has occurred twice; both times the intended
# topology was written only in an ADR, where no machine could read it.
#
# Usage: validate-idp-topology.sh [ROOT_DIR]
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
CONFIG="${ROOT}/opentofu/config.tm.hcl"
KNOWN_CLOUDS="aws gcp"
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

if [ ! -f "$CONFIG" ]; then
  echo "FAIL: no ${CONFIG}"
  exit 1
fi

primary="$(sed -n 's/^[[:space:]]*primary_cloud[[:space:]]*=[[:space:]]*"\([a-z0-9]*\)".*/\1/p' "$CONFIG" | head -1)"

if [ -z "$primary" ]; then
  echo "FAIL: primary_cloud is not declared in opentofu/config.tm.hcl."
  echo "      ADR-0027 requires one named home for services that cannot exist twice."
  exit 1
fi

if ! grep -qw "$primary" <<<"$KNOWN_CLOUDS"; then
  echo "FAIL: primary_cloud = \"${primary}\" is not a known cloud (${KNOWN_CLOUDS})."
  exit 1
fi

shopt -s nullglob
manifests=("${ROOT}"/clusters/*/security/zitadel.yaml)
shopt -u nullglob

if [ ${#manifests[@]} -eq 0 ]; then
  echo "FAIL: no clusters/*/security/zitadel.yaml found under ${ROOT}"
  exit 1
fi

for manifest in "${manifests[@]}"; do
  cluster="$(basename "$(dirname "$(dirname "$manifest")")")"
  cloud="${cluster%%-*}"

  # An absent spec.suspend means not suspended, which is how Flux reads it.
  suspend="$(python3 - "$manifest" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}
print(str((doc.get("spec") or {}).get("suspend", False)).lower())
PY
)"

  if [ "$cloud" = "$primary" ]; then
    if [ "$suspend" = "true" ]; then
      fail "${cluster} is on the primary cloud (${primary}) but its identity provider is suspended."
      echo "      Set spec.suspend: false in clusters/${cluster}/security/zitadel.yaml,"
      echo "      or change primary_cloud in opentofu/config.tm.hcl."
    fi
  else
    if [ "$suspend" != "true" ]; then
      fail "${cluster} is not on the primary cloud (${primary}) but would run its own identity provider."
      if [ "$cloud" = "aws" ]; then
        echo "      opentofu/aws/eks/configure sets identity_provider_url unconditionally, so AWS"
        echo "      hosts whenever it is deployed. A non-AWS primary with AWS deployed is not a"
        echo "      supported combination -- it needs an AWS-side host toggle, which is a new decision."
      else
        echo "      Set spec.suspend: true in clusters/${cluster}/security/zitadel.yaml."
      fi
    fi
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "==> identity provider topology is inconsistent (${failures} problem(s)); see ADR-0027."
  exit 1
fi

echo "==> identity provider topology is consistent: ${primary} hosts, all other clouds suspended."
