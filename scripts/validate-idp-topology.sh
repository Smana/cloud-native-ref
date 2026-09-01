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
# SCOPE: this reads COMMITTED YAML, not a live cluster. It answers "would this
# configuration produce two identity directories?", not "are two running right
# now?" -- suspending a Kustomization stops Flux reconciling an instance without
# removing one already deployed, so a live migration can be mid-flight with two
# directories up while this reports consistent. That case belongs to the
# migration guide's decommissioning step, not here.
#
# Usage: validate-idp-topology.sh [ROOT_DIR]
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
CONFIG="${ROOT}/opentofu/config.tm.hcl"
# A third copy of the cloud list -- the others are global.stack_cloud in
# opentofu/config.tm.hcl and --tm-check in scripts/tm-provisioner.sh. Adding a
# lane means adding it here too; see the checklist in
# website/content/docs/guides/add-a-cloud-provider.md.
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

# Match ANY quoted value, not just lowercase words: a malformed value such as
# "AWS" must reach the known-cloud check below with its useful message, rather
# than failing to match here and being reported as "not declared" -- pointing
# the reader at a line that is plainly right there in the file.
primary="$(sed -n 's/^[[:space:]]*primary_cloud[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"

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

hosts=0

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
    else
      hosts=$((hosts + 1))
    fi
  elif [ "$cloud" = "aws" ]; then
    # Unsupported REGARDLESS of suspend: opentofu/aws/eks/configure sets
    # identity_provider_url unconditionally, so deploying AWS at all points every
    # aws-0 consumer at auth.<aws public domain>. Suspending the Kustomization
    # stops AWS hosting but leaves its consumers aimed at a host nothing serves --
    # the other silent failure this check exists to catch, so it cannot be the
    # way out of the first one.
    fail "primary_cloud is \"${primary}\", but the AWS cluster ${cluster} is present."
    echo "      opentofu/aws/eks/configure sets identity_provider_url unconditionally, so AWS"
    echo "      cannot consume another cloud's identity provider. A non-AWS primary with AWS"
    echo "      deployed needs an AWS-side host toggle, which is a new decision -- not a"
    echo "      suspend. See ADR-0027."
  elif [ "$suspend" != "true" ]; then
    fail "${cluster} is not on the primary cloud (${primary}) but would run its own identity provider."
    echo "      Set spec.suspend: true in clusters/${cluster}/security/zitadel.yaml."
  fi
done

# The contract is "exactly one", not "none misplaced": with only the per-manifest
# rules above, a tree with no manifest on the primary cloud -- or with the primary
# cloud's manifest deleted outright -- passes while nothing hosts at all.
if [ "$hosts" -ne 1 ]; then
  fail "expected exactly one cluster to host the identity provider, found ${hosts}."
  echo "      primary_cloud is \"${primary}\"; check that a clusters/${primary}-*/security/"
  echo "      zitadel.yaml exists and is not suspended, and that only one is."
fi

if [ "$failures" -ne 0 ]; then
  echo "==> identity provider topology is inconsistent (${failures} problem(s)); see ADR-0027."
  exit 1
fi

echo "==> identity provider topology is consistent: ${primary} hosts, all other clouds suspended."
