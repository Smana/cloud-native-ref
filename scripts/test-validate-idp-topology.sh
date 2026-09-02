#!/usr/bin/env bash
#
# Fixture-driven tests for validate-idp-topology.sh.
#
# The states this checker exists to catch are expensive to produce live -- two
# clusters each running an identity provider is a two-cloud bootstrap -- so it
# is tested against synthetic trees instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-idp-topology.sh"
failures=0

# Build a fixture tree: primary cloud, then "<cluster>:<suspend>" pairs where
# suspend is "true", "false", or "absent".
make_fixture() {
  local root="$1" primary="$2"
  shift 2
  mkdir -p "${root}/opentofu"
  # "absent" omits the declaration entirely -- the same sentinel spelling the
  # suspend pairs use below, so every case can go through `expect`.
  if [ "$primary" = "absent" ]; then
    printf 'globals {\n  region = "eu-west-3"\n}\n' >"${root}/opentofu/config.tm.hcl"
  else
    cat >"${root}/opentofu/config.tm.hcl" <<EOF
globals {
  region        = "eu-west-3"
  primary_cloud = "${primary}"
}
EOF
  fi
  local pair cluster suspend
  for pair in "$@"; do
    cluster="${pair%%:*}"
    suspend="${pair##*:}"
    mkdir -p "${root}/clusters/${cluster}/security"
    {
      echo "apiVersion: kustomize.toolkit.fluxcd.io/v1"
      echo "kind: Kustomization"
      echo "metadata:"
      echo "  name: zitadel"
      echo "spec:"
      [ "$suspend" != "absent" ] && echo "  suspend: ${suspend}"
      echo "  path: ./security/${cluster}/zitadel"
    } >"${root}/clusters/${cluster}/security/zitadel.yaml"
  done
}

# expect <name> <expected-exit> <expected-substring-or-empty> <primary> <pairs...>
expect() {
  local name="$1" want_exit="$2" want_text="$3" primary="$4"
  shift 4
  local root output rc
  root="$(mktemp -d)"
  make_fixture "$root" "$primary" "$@"
  set +e
  output="$("$VALIDATOR" "$root" 2>&1)"
  rc=$?
  set -e
  rm -rf "$root"

  if [ "$rc" -ne "$want_exit" ]; then
    echo "FAIL ${name}: exit ${rc}, want ${want_exit}"
    echo "     output: ${output}"
    failures=$((failures + 1))
    return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<<"$output"; then
    echo "FAIL ${name}: output missing '${want_text}'"
    echo "     output: ${output}"
    failures=$((failures + 1))
    return
  fi
  echo "ok   ${name}"
}

expect "compliant: aws primary hosts, gcp suspended" \
  0 "" aws "aws-0:absent" "gcp-0:true"

expect "both clouds hosting is rejected" \
  1 "gcp-0" aws "aws-0:absent" "gcp-0:false"

expect "primary hosting nothing is rejected" \
  1 "aws-0" aws "aws-0:true" "gcp-0:true"

# GCP primary is a SUPPORTED configuration, and the tree always contains
# clusters/aws-0/security/zitadel.yaml because it is a committed file. An
# earlier version treated that file's mere presence as proof AWS was deployed
# and rejected the whole configuration, making GCP-only impossible to commit --
# this case is here so that cannot come back.
expect "gcp primary with aws suspended is accepted" \
  0 "" gcp "aws-0:true" "gcp-0:false"

# ...and the mirror image is still caught: GCP primary while aws-0 would also
# host is two directories, whichever cloud is primary.
expect "gcp primary with aws also hosting is rejected" \
  1 "aws-0" gcp "aws-0:false" "gcp-0:false"

expect "unknown primary_cloud is rejected" \
  1 "azure" azure "aws-0:absent" "gcp-0:true"

expect "malformed primary_cloud reports as invalid, not undeclared" \
  1 "not a known cloud" AWS "aws-0:absent" "gcp-0:true"

expect "undeclared primary_cloud is rejected" \
  1 "primary_cloud" absent "aws-0:false"

# "Exactly one hosts" is the contract; these two would pass a purely
# per-manifest rule while zero or two clusters actually host.
expect "no cluster on the primary cloud is rejected" \
  1 "found 0" aws "gcp-0:true"

expect "two clusters on the primary cloud both hosting is rejected" \
  1 "found 2" aws "aws-0:absent" "aws-1:false" "gcp-0:true"

if [ "$failures" -ne 0 ]; then
  echo "==> ${failures} test(s) failed"
  exit 1
fi
echo "==> all tests passed"
