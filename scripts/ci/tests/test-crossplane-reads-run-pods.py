#!/usr/bin/env python3
# requires: python3
"""Crossplane reads an AgentRun's pod (disruption design §3): the composition asks for it as a
required resource, which Crossplane 2.4 serves from a cluster-wide informer. With get alone the XR
loops on "failed waiting for *unstructured.Unstructured Informer to sync" (infrastructure/AGENTS.md,
trap 3)."""
import pathlib
import sys

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
RBAC = ROOT / "infrastructure/base/agent-sandbox/rbac-crossplane.yaml"
docs = [d for d in yaml.safe_load_all(RBAC.read_text()) if d]
aggregated = [d for d in docs if d["kind"] == "ClusterRole"
              and d["metadata"].get("labels", {}).get("rbac.crossplane.io/aggregate-to-crossplane") == "true"]
granted = {verb for role in aggregated for rule in role.get("rules", [])
           if "" in rule.get("apiGroups", []) and "pods" in rule.get("resources", []) for verb in rule.get("verbs", [])}
errors = []
if not {"get", "list", "watch"} <= granted:
    errors.append(f"Crossplane's aggregate role grants pods {sorted(granted)}; the required-resource read needs get, list and watch")
if granted - {"get", "list", "watch"}:
    errors.append(f"Crossplane only reads pods, got {sorted(granted)}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
