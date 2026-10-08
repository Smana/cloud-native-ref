#!/usr/bin/env bash
#
# What the agent platform needs on gcp-0 before any child applies (GCP parity):
# the gcp package at the same crossplane-configuration version as aws, whose core
# dependency ships the AgentRun XRD, and Kyverno, which agent-policies needs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0; f() { echo "FAIL $*"; fails=$((fails + 1)); }
tag() { sed -n "s#.*crossplane-configuration-$1:\(v[^[:space:]\"']*\).*#\1#p" "$ROOT/infrastructure/base/crossplane/configuration-$1/configuration-packages.yaml" | head -1; }
aws="$(tag aws)"; gcp="$(tag gcp)"
[ -n "$aws" ] && [ "$aws" = "$gcp" ] || f "crossplane-configuration pins differ: aws=$aws gcp=$gcp"
# The AgentRun XRD first shipped in the agentrun pre-releases; v0.7.1 and older carry none (GP-25).
case "$gcp" in v0.7.[01]|v0.[0-6].*) f "the gcp pin $gcp predates the AgentRun XRD" ;; esac
grep -q 'name: kyverno$' "$ROOT/clusters/gcp-0/security/security.yaml" || f "gcp-0's security Kustomization does not health-check kyverno"
if [ -e "$ROOT/clusters/gcp-0-agent-platform/security-agent-policies.yaml" ] || [ ! -d "$ROOT/clusters/gcp-0-agent-platform" ]; then
  grep -q '\.\./\.\./base/kyverno' "$ROOT/security/gcp-0/controllers/kustomization.yaml" || f "gcp-0's security Kustomization has no Kyverno"
fi
[ "$fails" -eq 0 ] || exit 1
echo PASS
