#!/usr/bin/env bash
# requires: python3
#
# GCP parity GP-9..GP-11: gcp-0's runs land on a GKE Sandbox pool through GKE's
# own `gvisor` RuntimeClass; gVisor needs Cilium's per-packet LB; and every
# DaemonSet that follows runs onto aws-0's gVisor nodes follows them onto GKE's.
# F2: every GKE pool and ComputeClass carries Cilium's startup taint under the
# key Cilium clears, in the autoscaler's startup-taint namespace, so the pool
# scales from zero with NO toleration and nothing runs before Cilium is ready.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/opentofu/gcp/gke/init/sandbox.tf"
C="$ROOT/opentofu/gcp/gke/init/helm_values/cilium.yaml"
fails=0; fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
if [ -f "$F" ]; then
  grep -Eq 'sandbox_type[[:space:]]*=[[:space:]]*"gvisor"' "$F" || fail "the pool is not a GKE Sandbox pool"
  grep -Eq 'spot[[:space:]]*=[[:space:]]*true' "$F" || fail "the pool is not spot"
  grep -Eq 'min_node_count[[:space:]]*=[[:space:]]*0' "$F" || fail "the pool does not scale to zero"
  grep -Eq 'key[[:space:]]*=[[:space:]]*local\.cilium_agent_not_ready_taint' "$F" || fail "no Cilium startup taint"
  grep -Eq 'disk_type[[:space:]]*=[[:space:]]*"pd-standard"' "$F" || fail "the pool's disk is not pd-standard, the cheapest"
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

# The toleration path and the probe, parsed rather than grepped.
out="$(python3 - "$ROOT" <<'PY'
import pathlib, sys
try:
    import yaml
except ImportError:
    print("SKIP PyYAML is not installed"); sys.exit(0)
root = pathlib.Path(sys.argv[1])
def docs(p):
    return [d for d in yaml.safe_load_all(p.read_text()) if d] if p.is_file() else []

# One taint key everywhere on GKE: cilium-operator clears only the key it is
# configured with, so a pool carrying another one never becomes schedulable.
import re
prefixes = ("ignore-taint.cluster-autoscaler.kubernetes.io/", "startup-taint.cluster-autoscaler.kubernetes.io/")
cilium = docs(root / "opentofu/gcp/gke/init/helm_values/cilium.yaml")
taint_key = (cilium[0] if cilium else {}).get("agentNotReadyTaintKey")
if not taint_key or not taint_key.startswith(prefixes):
    print(f"FAIL cilium.yaml: agentNotReadyTaintKey must carry an autoscaler startup-taint prefix, got {taint_key!r}")
m = re.search(r'cilium_agent_not_ready_taint\s*=\s*"([^"]+)"', (root / "opentofu/gcp/gke/init/main.tf").read_text())
if not m or m.group(1) != taint_key:
    print(f"FAIL gke/init local.cilium_agent_not_ready_taint != cilium.yaml agentNotReadyTaintKey ({taint_key!r})")
if not re.search(r'key\s*=\s*local\.cilium_agent_not_ready_taint', (root / "opentofu/gcp/gke/init/main.tf").read_text()):
    print("FAIL the static pool does not carry local.cilium_agent_not_ready_taint")
for p in sorted((root / "infrastructure/gcp-0/computeclass").glob("*.yaml")):
    for d in docs(p):
        if d.get("kind") != "ComputeClass":
            continue
        taints = [t.get("key") for t in (d["spec"].get("nodePoolConfig") or {}).get("taints", [])]
        if taint_key not in taints:
            print(f"FAIL ComputeClass {d['metadata']['name']} does not carry the Cilium taint {taint_key!r}")

# A toleration of that key re-opens F2: the pod lands before Cilium, unpoliced.
for base in ("clusters/gcp-0", "clusters/gcp-0-agent-platform", "infrastructure", "security",
             "observability", "tooling", "apps", "scripts/ops"):
    for p in (root / base).rglob("*.yaml"):
        if taint_key and taint_key in p.read_text() and "computeclass" not in p.parts:
            print(f"FAIL {p.relative_to(root)} names the Cilium startup taint; nothing may tolerate it")

# The cluster autoscaler's ceiling counts every node, the fixed pools included.
init = root / "opentofu/gcp/gke/init"
tfvars = (init / "variables.tfvars").read_text() if (init / "variables.tfvars").is_file() else ""
tfvars_src = (init / "variables.tf").read_text() if (init / "variables.tf").is_file() else ""
def var(name):
    m = re.search(rf'(?m)^{name}\s*=\s*"?([^"\s]+)"?', tfvars)
    if not m:
        m = re.search(rf'variable "{name}" \{{.*?default\s*=\s*"?([^"\s]+)"?', tfvars_src, re.S)
    return m.group(1) if m else None
def e2(mt):  # (vCPU, GiB) of an e2-standard-N
    m = re.fullmatch(r"e2-standard-(\d+)", mt or "")
    return (int(m.group(1)), 4 * int(m.group(1))) if m else None
# The gpu-l4 class's L4 allowance is also a fixed maximum (one L4 per
# g2-standard-4: 4 vCPU / 16 GiB), and it must fit beside both pools too.
gpu = re.search(r'resource_type\s*=\s*"nvidia-l4".*?maximum\s*=\s*(\d+)',
                (init / "main.tf").read_text() if (init / "main.tf").is_file() else "", re.S)
ngpu = int(gpu.group(1)) if gpu else 0
static, agents = e2(var("node_machine_type")), e2(var("agents_pool_machine_type"))
if static and agents:
    ns, na = int(var("node_max_count")), int(var("agents_pool_max_nodes"))
    for i, (key, unit) in enumerate([("autoscaling_max_cpu_cores", "vCPU"), ("autoscaling_max_memory_gb", "GiB")]):
        need = ns * static[i] + na * agents[i] + ngpu * (4, 16)[i]
        have = int(var(key))
        if have < need:
            print(f"FAIL {key} = {have} < static max + agents max + L4 allowance = {need} {unit}: "
                  "agent nodes are refused (NotTriggerScaleUp: max cluster limit reached)")
else:
    print("FAIL cannot size the fixed pools: a machine type is not e2-standard-N; extend this check")

probe = docs(root / "scripts/ops/k8s/gvisor-smoke.yaml")
if not probe:
    print("FAIL no scripts/ops/k8s/gvisor-smoke.yaml")
for d in probe:
    if d.get("kind") == "CiliumNetworkPolicy" and d["spec"].get("ingress") != [{}]:
        print("FAIL the probe's CNP must deny ingress with the `- {}` idiom")
    if d.get("kind") == "Pod":
        s = d["spec"]
        if any("agent-not-ready" in str(t.get("key")) for t in s.get("tolerations") or []):
            print("FAIL the probe tolerates a Cilium startup taint: it must prove scale-up without one")
        if not s.get("activeDeadlineSeconds"):
            print("FAIL the probe has no activeDeadlineSeconds")
        if '!= "4.4.0"' not in "".join(s["containers"][0].get("command", [])):
            print("FAIL the probe does not assert it runs under gVisor (release 4.4.0)")
PY
)"
case "$out" in SKIP*) echo "${out#SKIP }"; exit 77 ;; esac
[ -n "$out" ] && printf '%s\n' "$out" >&2
fails=$((fails + $(printf '%s\n' "$out" | grep -c '^FAIL')))
[ "$fails" -eq 0 ] || exit 1
echo PASS
