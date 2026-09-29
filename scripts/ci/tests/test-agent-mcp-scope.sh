#!/usr/bin/env bash
# requires: python3
#
# External review M2 and M3 (SP2 ruling P39): no role gets VictoriaMetrics' operator
# introspection, an internal implementer gets no arbitrary-kind resource read, and the Flux
# MCP server reads ConfigMaps and pod logs in flux-system only. The real tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
ROOT="$ROOT" python3 - <<'PY'
import os, sys, yaml

root = os.environ["ROOT"]
base = os.path.join(root, "infrastructure/base/agent-mcp")
INTROSPECTION = {"tsdb_status", "active_queries", "top_queries"}
errors = []

for route in yaml.safe_load_all(open(os.path.join(base, "mcproutes.yaml"))):
    if not route or route.get("kind") != "MCPRoute":
        continue
    name = route["metadata"]["name"]
    for backend in route["spec"]["backendRefs"]:
        if INTROSPECTION & set((backend.get("toolSelector") or {}).get("include") or []):
            errors.append(f"{name}: backend {backend['name']} exposes {sorted(INTROSPECTION)}")
    for rule in route["spec"]["securityPolicy"]["authorization"]["rules"]:
        auds = {v for c in rule["source"]["jwt"]["claims"] for v in c["values"]}
        tools = {t["tool"] for t in rule["target"]["tools"]}
        if INTROSPECTION & tools:
            errors.append(f"{name}: {sorted(auds)} granted {sorted(INTROSPECTION & tools)}")
        if "agent-router.implementer.internal" in auds and "get_kubernetes_resources" in tools:
            errors.append(f"{name}: the internal implementer holds get_kubernetes_resources")

docs = list(yaml.safe_load_all(open(os.path.join(base, "flux-operator-mcp-rbac.yaml"))))
cluster = next(d for d in docs if d and d["kind"] == "ClusterRole")
wide = {r for rule in cluster["rules"] if "" in rule["apiGroups"] for r in rule["resources"]}
for r in ("configmaps", "serviceaccounts", "nodes", "pods/log"):
    if r in wide:
        errors.append(f"ClusterRole {cluster['metadata']['name']} reads {r} cluster-wide")
role = next((d for d in docs if d and d["kind"] == "Role" and d["metadata"]["namespace"] == "flux-system"), None)
if role is None or {"configmaps", "pods/log"} - {r for rule in role["rules"] for r in rule["resources"]}:
    errors.append("no Role in flux-system grants configmaps and pods/log")
if not any(d and d["kind"] == "RoleBinding" and d["metadata"]["namespace"] == "flux-system"
           and d["subjects"][0]["name"] == "flux-operator-mcp" for d in docs):
    errors.append("no RoleBinding gives flux-operator-mcp the flux-system Role")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
PY
