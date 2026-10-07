#!/usr/bin/env python3
# requires: python3
"""The log shipper outlives the pods it ships for at node shutdown. The kubelet stops regular pods
first and critical ones (priority >= system-cluster-critical) in the last window; at priority 0,
Vector stopped beside an AgentRun pod on aws-0 (2026-10-07) and never shipped its final lines.
GKE admits the system-* classes outside kube-system only with a matching ResourceQuota, so the
class is useless without the quota in the shipper's namespace."""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
CLASS = "system-node-critical"
fails = []

for name in ("helmrelease-vlsingle.yaml", "helmrelease-vlcluster.yaml"):
    hr = yaml.safe_load((ROOT / "observability/base/victoria-logs" / name).read_text())
    got = ((hr["spec"].get("values") or {}).get("vector") or {}).get("podPriorityClassName")
    if got != CLASS:
        fails.append(f"{name}: vector.podPriorityClassName is {got!r}, want {CLASS!r}")

docs = list(yaml.safe_load_all((ROOT / "namespaces/base/observability.yaml").read_text()))
quotas = [d for d in docs if d and d.get("kind") == "ResourceQuota" and d["metadata"].get("namespace") == "observability"]
admits = [q for q in quotas if (q["spec"].get("hard") or {}).get("pods") and any(
    e.get("scopeName") == "PriorityClass" and e.get("operator") == "In" and CLASS in (e.get("values") or [])
    for e in (q["spec"].get("scopeSelector") or {}).get("matchExpressions") or [])]
if not admits:
    fails.append(f"namespaces/base/observability.yaml: no ResourceQuota admits {CLASS} pods in observability")

for f in fails:
    print("FAIL " + f)
if fails:
    sys.exit(1)
print("PASS")
