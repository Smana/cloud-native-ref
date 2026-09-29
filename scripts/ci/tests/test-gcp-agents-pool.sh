#!/usr/bin/env bash
# requires: python3
#
# GCP parity GP-9..GP-11: gcp-0's runs land on a GKE Sandbox pool through GKE's
# own `gvisor` RuntimeClass; gVisor needs Cilium's per-packet LB; and every
# DaemonSet that follows runs onto aws-0's gVisor nodes follows them onto GKE's.
# The pool keeps Cilium's startup taint, so it scales from zero only for pods
# that tolerate it (ADR-0006): a Kyverno policy adds that toleration to gVisor pods.
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
want = {"key": "node.cilium.io/agent-not-ready", "operator": "Exists", "effect": "NoSchedule"}
def docs(p):
    return [d for d in yaml.safe_load_all(p.read_text()) if d] if p.is_file() else []

pol_dir = root / "security/gcp-0/sandbox-policies"
kust = docs(pol_dir / "kustomization.yaml")
pols = [d for r in (kust[0].get("resources", []) if kust else []) for d in docs(pol_dir / r)
        if d.get("kind") == "ClusterPolicy"]
if not pols:
    print("FAIL no Kyverno ClusterPolicy in security/gcp-0/sandbox-policies")
for pol in pols:
    rules = [r for r in pol["spec"].get("rules", []) if "mutate" in r]
    ok = False
    for r in rules:
        pre = r.get("preconditions", {}).get("all", [])
        gvisor = any("runtimeClassName" in str(c.get("key")) and c.get("operator") == "Equals"
                     and c.get("value") == "gvisor" for c in pre)
        patch = yaml.safe_load(r["mutate"].get("patchesJson6902", "[]")) or []
        adds = any(p.get("op") == "add" and p.get("path") == "/spec/tolerations/-" and p.get("value") == want
                   for p in patch)
        ok = ok or (gvisor and adds)
    if not ok:
        print(f"FAIL {pol['metadata']['name']}: no rule adds {want} to pods with runtimeClassName gvisor")
    if pol["metadata"].get("annotations", {}).get("pod-policies.kyverno.io/autogen-controllers") != "none":
        print(f"FAIL {pol['metadata']['name']}: autogen must be off, or it patches Deployment templates")

wired = [d for p in (root / "clusters/gcp-0").rglob("*.yaml") for d in docs(p)
         if d.get("kind") == "Kustomization" and str(d.get("spec", {}).get("path", "")).rstrip("/") == "./security/gcp-0/sandbox-policies"]
if not wired:
    print("FAIL no gcp-0 Flux Kustomization applies security/gcp-0/sandbox-policies")
for k in wired:
    if "security" not in [x.get("name") for x in k["spec"].get("dependsOn", [])]:
        print(f"FAIL {k['metadata']['name']} must dependsOn security, which health-checks kyverno")

probe = docs(root / "scripts/ops/k8s/gvisor-smoke.yaml")
if not probe:
    print("FAIL no scripts/ops/k8s/gvisor-smoke.yaml")
for d in probe:
    if d.get("kind") == "CiliumNetworkPolicy" and d["spec"].get("ingress") != [{}]:
        print("FAIL the probe's CNP must deny ingress with the `- {}` idiom")
    if d.get("kind") == "Pod":
        s = d["spec"]
        if want not in s.get("tolerations", []):
            print("FAIL the probe does not tolerate the Cilium startup taint")
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
