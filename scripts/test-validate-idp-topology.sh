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
  cat >"${root}/opentofu/config.tm.hcl" <<EOF
globals {
  region        = "eu-west-3"
  primary_cloud = "${primary}"
}
EOF
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

expect "gcp primary while aws is present is rejected" \
  1 "unconditionally" gcp "aws-0:absent" "gcp-0:false"

expect "unknown primary_cloud is rejected" \
  1 "azure" azure "aws-0:absent" "gcp-0:true"

# primary_cloud absent entirely
root="$(mktemp -d)"
mkdir -p "${root}/opentofu"
echo 'globals {' >"${root}/opentofu/config.tm.hcl"
echo '  region = "eu-west-3"' >>"${root}/opentofu/config.tm.hcl"
echo '}' >>"${root}/opentofu/config.tm.hcl"
mkdir -p "${root}/clusters/aws-0/security"
printf 'spec:\n  suspend: false\n' >"${root}/clusters/aws-0/security/zitadel.yaml"
set +e
out="$("$VALIDATOR" "$root" 2>&1)"; rc=$?
set -e
rm -rf "$root"
if [ "$rc" -eq 1 ] && grep -qF "primary_cloud" <<<"$out"; then
  echo "ok   undeclared primary_cloud is rejected"
else
  echo "FAIL undeclared primary_cloud is rejected: exit ${rc}: ${out}"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "==> ${failures} test(s) failed"
  exit 1
fi
echo "==> all tests passed"
