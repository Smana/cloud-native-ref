#!/usr/bin/env bash
# requires: python3
#
# GCP parity GP-9..GP-11: gcp-0's runs land on a GKE Sandbox pool through GKE's
# own `gvisor` RuntimeClass; gVisor needs Cilium's per-packet LB; and every
# DaemonSet that follows runs onto aws-0's gVisor nodes follows them onto GKE's.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/opentofu/gcp/gke/init/sandbox.tf"
C="$ROOT/opentofu/gcp/gke/init/helm_values/cilium.yaml"
fails=0; fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
if [ -f "$F" ]; then
  grep -Eq 'sandbox_type[[:space:]]*=[[:space:]]*"gvisor"' "$F" || fail "the pool is not a GKE Sandbox pool"
  grep -Eq 'spot[[:space:]]*=[[:space:]]*true' "$F" || fail "the pool is not spot"
  grep -Eq 'min_node_count[[:space:]]*=[[:space:]]*0' "$F" || fail "the pool does not scale to zero"
  grep -q 'node.cilium.io/agent-not-ready' "$F" || fail "no Cilium startup taint"
else
  fail "no $F"
fi
python3 - "$C" <<'PY' || fail "cilium.yaml: socketLB.hostNamespaceOnly must be true"
import re, sys
sys.exit(0 if re.search(r'(?m)^socketLB:\n[ \t]+hostNamespaceOnly:[ \t]*true\b', open(sys.argv[1]).read()) else 1)
PY
grep -rqs 'runtimeclass-gvisor\|karpenter-nodepools-agents' "$ROOT"/clusters/gcp-0* \
  && fail "gcp-0 must not apply aws-0's RuntimeClass or Karpenter pool: GKE ships both"
while IFS= read -r f; do
  grep -q 'sandbox.gke.io/runtime' "$f" || fail "$f tolerates agents.ogenki.io/runtime but not sandbox.gke.io/runtime"
done < <(grep -rl --include=*.yaml 'key: agents.ogenki.io/runtime' "$ROOT/observability" "$ROOT/infrastructure" "$ROOT/security" | grep -v -e karpenter-nodepools-agents -e runtimeclass-gvisor)
[ -f "$ROOT/scripts/ops/k8s/gvisor-smoke.yaml" ] || fail "no scripts/ops/k8s/gvisor-smoke.yaml"
[ "$fails" -eq 0 ] || exit 1
echo PASS
