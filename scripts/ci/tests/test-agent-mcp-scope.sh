#!/usr/bin/env bash
# requires: python3
#
# External review M2 and M3 (SP2 ruling P39): no role gets VictoriaMetrics' operator
# introspection, an internal implementer gets no arbitrary-kind resource read, and the Flux
# MCP server reads ConfigMaps and pod logs in flux-system only. The real tree.
#
# Allowlists, not denylists (review round 1): a set that must equal an exact expectation
# catches an addition denylisting three tool names never could -- `flags`/`export` sneaking
# onto a backend's toolSelector, `get_kubernetes_logs` sneaking onto the implementer's grant,
# `secrets` or `resources: ["*"]` sneaking onto a Role or ClusterRole bound to the MCP
# server's ServiceAccount, or a second RoleBinding to that ServiceAccount within
# flux-operator-mcp-rbac.yaml (the only file this suite parses for RBAC).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
ROOT="$ROOT" python3 - <<'PY'
import os, sys, yaml

root = os.environ["ROOT"]
base = os.path.join(root, "infrastructure/base/agent-mcp")
errors = []

SA_NAME = "flux-operator-mcp"
SA_NS = "agent-system"
FORBIDDEN = {"secrets", "*"}

# --- Exact tool sets per role, not a denylist of three introspection names ---

VM_TOOLS = {"documentation", "query", "query_range", "metrics", "metrics_metadata", "labels",
            "label_values", "series", "alerts", "rules", "explain_query", "prettify_query",
            "metric_statistics"}
VL_TOOLS = {"documentation", "query", "hits", "facets", "field_names", "field_values",
            "stats_query", "stats_query_range", "streams", "stream_ids", "stream_field_names",
            "stream_field_values"}

# SP2 §3: the same room tools on both listeners; room_handoff is not a reviewer's,
# room_verdict is not an implementer's or a triager's.
ROOM_TOOLS = {"room_read", "room_post", "room_progress", "room_handoff", "room_verdict"}
ROOM_GRANTS = {
    "implementer": {"room_read", "room_post", "room_progress", "room_handoff"},
    "reviewer": {"room_read", "room_post", "room_progress", "room_verdict"},
    "tester": ROOM_TOOLS,
    "triager": {"room_read", "room_post", "room_progress", "room_handoff"},
}

EXPECTED_BACKEND_TOOLS = {
    "agent-mcp-public": {
        "flux-operator-mcp": {"search_flux_docs"},
        "mcp-victoriametrics": {"documentation"},
        "mcp-victorialogs": {"documentation"},
        "room-broker": ROOM_TOOLS,
    },
    "agent-mcp-internal": {
        "flux-operator-mcp": {"search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions",
                               "get_kubernetes_resources", "get_kubernetes_metrics", "get_kubernetes_logs"},
        "mcp-victoriametrics": VM_TOOLS,
        "mcp-victorialogs": VL_TOOLS,
        "room-broker": ROOM_TOOLS,
    },
}

_IMPLEMENTER_INTERNAL = {
    "flux-operator-mcp": {"search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions",
                           "get_kubernetes_metrics"},
    "mcp-victoriametrics": VM_TOOLS,
    "mcp-victorialogs": {"documentation"},
}
_FULL_READER_INTERNAL = {
    "flux-operator-mcp": {"search_flux_docs", "get_flux_instance", "get_kubernetes_api_versions",
                           "get_kubernetes_resources", "get_kubernetes_metrics", "get_kubernetes_logs"},
    "mcp-victoriametrics": VM_TOOLS,
    "mcp-victorialogs": VL_TOOLS,
}
_DOCS_ONLY_PUBLIC = {
    "flux-operator-mcp": {"search_flux_docs"},
    "mcp-victoriametrics": {"documentation"},
    "mcp-victorialogs": {"documentation"},
}

def with_room(grants, role):
    return {**grants, "room-broker": ROOM_GRANTS[role]}

EXPECTED_ROLE_TOOLS = {
    "agent-mcp-public": {
        "agent-router.implementer.public": with_room(_DOCS_ONLY_PUBLIC, "implementer"),
        "agent-router.reviewer.public": with_room(_DOCS_ONLY_PUBLIC, "reviewer"),
        "agent-router.tester.public": with_room(_DOCS_ONLY_PUBLIC, "tester"),
        "agent-router.triager.public": with_room(_DOCS_ONLY_PUBLIC, "triager"),
    },
    "agent-mcp-internal": {
        "agent-router.implementer.internal": with_room(_IMPLEMENTER_INTERNAL, "implementer"),
        "agent-router.reviewer.internal": with_room(_FULL_READER_INTERNAL, "reviewer"),
        "agent-router.tester.internal": with_room(_FULL_READER_INTERNAL, "tester"),
        "agent-router.triager.internal": with_room(_FULL_READER_INTERNAL, "triager"),
    },
}

# --- agentgateway's Allow lists (ADR-0053) must grant exactly these sets ---
# Each expression must be one alternative in the gate's grammar (AG6), so the grants can
# be recomputed exactly; one outside it is an error here too.
import importlib.util, re
sys.path.insert(0, os.path.join(root, "scripts/ci/flux-schema"))
_spec = importlib.util.spec_from_file_location(
    "agw_gate", os.path.join(root, "scripts/ci/flux-schema/assert-agent-gateway.py"))
_agw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_agw)
grammar = _agw.alternative(_agw.PROFILES[("agent-gateway", "agent-router")])

AGW_FILE = os.path.join(root, "infrastructure/base/agent-gateway/mcp.yaml")
AGW_ROUTES = {"agentgateway-mcp-public": "agent-mcp-public", "agentgateway-mcp-internal": "agent-mcp-internal"}
agw_docs = [d for d in yaml.safe_load_all(open(AGW_FILE)) if d]
backends = [d for d in agw_docs if d["kind"] == "AgentgatewayBackend"]
if len(backends) != 1:
    errors.append(f"agent-gateway/mcp.yaml: expected one AgentgatewayBackend, found {len(backends)}")
else:
    mcp = backends[0]["spec"]["mcp"]
    if mcp.get("prefixMode") != "Always":
        errors.append("agent-mcp backend: prefixMode must be Always, so tools read <target>_<tool>")
    if mcp.get("sessionRouting") != "Stateless":
        errors.append("agent-mcp backend: sessionRouting must be Stateless (#3834, #3622)")
    names = {t["name"] for t in mcp["targets"]}
    want = set(EXPECTED_BACKEND_TOOLS["agent-mcp-public"])
    if names != want:
        errors.append(f"agent-mcp backend targets are {sorted(names)}, expected {sorted(want)}")
seen_policies = set()
for pol in (d for d in agw_docs if d["kind"] == "AgentgatewayPolicy"):
    name = pol["metadata"]["name"]
    if name not in AGW_ROUTES:
        errors.append(f"agent-gateway/mcp.yaml: unexpected policy {name}")
        continue
    seen_policies.add(name)
    authz = pol["spec"]["backend"]["mcp"]["authorization"]
    if authz.get("action") != "Allow":
        errors.append(f"{name}: MCP authorization must be an Allow list")
    got = {}
    for e in authz["policy"]["matchExpressions"]:
        m = grammar.match(e.strip())
        if not m:
            errors.append(f"{name}: expression outside the canonical grammar: {e}")
            continue
        aud = f"agent-router.{m.group('role')}.{m.group('cls')}"
        tools = set(re.findall(r'"([a-z0-9_]+)"', m.group(0).split("mcp.tool.name", 1)[1]))
        got.setdefault(aud, {}).setdefault(m.group("target"), set()).update(tools)
    want = EXPECTED_ROLE_TOOLS[AGW_ROUTES[name]]
    if got != want:
        for aud in sorted(set(got) | set(want)):
            if got.get(aud) != want.get(aud):
                errors.append(f"{name}: {aud} grants {got.get(aud)}, expected {want.get(aud)}")
if seen_policies != set(AGW_ROUTES):
    errors.append(f"agent-gateway/mcp.yaml: missing Allow list(s) {sorted(set(AGW_ROUTES) - seen_policies)}")

# --- flux-operator-mcp RBAC: allowlist the flux-system Role, deny secrets/* anywhere the
#     ServiceAccount is bound, and require exactly one well-formed RoleBinding for it ---

def is_target_subject(subj):
    return (subj.get("kind") == "ServiceAccount" and subj.get("name") == SA_NAME
            and subj.get("namespace") == SA_NS)

docs = [d for d in yaml.safe_load_all(open(os.path.join(base, "flux-operator-mcp-rbac.yaml"))) if d]

roles = {}
cluster_roles = {}
role_bindings = []
cluster_role_bindings = []
for d in docs:
    kind = d.get("kind")
    if kind == "Role":
        roles[(d["metadata"]["namespace"], d["metadata"]["name"])] = d
    elif kind == "ClusterRole":
        cluster_roles[d["metadata"]["name"]] = d
    elif kind == "RoleBinding":
        role_bindings.append(d)
    elif kind == "ClusterRoleBinding":
        cluster_role_bindings.append(d)

flux_system_role = roles.get(("flux-system", "agent-mcp-flux-read"))
if flux_system_role is None:
    errors.append("no Role named agent-mcp-flux-read in flux-system")
else:
    resources, verbs, apigroups = set(), set(), set()
    for rule in flux_system_role["rules"]:
        apigroups |= set(rule.get("apiGroups", []))
        resources |= set(rule.get("resources", []))
        verbs |= set(rule.get("verbs", []))
    if apigroups != {""}:
        errors.append(f"flux-system Role apiGroups are {sorted(apigroups)}, expected only the core group")
    if resources != {"configmaps", "pods/log"}:
        errors.append(f"flux-system Role resources are {sorted(resources)}, expected exactly configmaps, pods/log")
    if verbs != {"get", "list", "watch"}:
        errors.append(f"flux-system Role verbs are {sorted(verbs)}, expected exactly get, list, watch")

matching_rbs = [rb for rb in role_bindings if any(is_target_subject(s) for s in rb.get("subjects", []))]
if len(matching_rbs) != 1:
    errors.append(f"expected exactly one RoleBinding for {SA_NS}/{SA_NAME}, found {len(matching_rbs)}")
else:
    rb = matching_rbs[0]
    ns = rb["metadata"]["namespace"]
    if ns != "flux-system":
        errors.append(f"the RoleBinding for {SA_NAME} is in {ns}, expected flux-system")
    subs = rb.get("subjects", [])
    if len(subs) != 1 or not is_target_subject(subs[0]):
        errors.append(f"RoleBinding subject is not exactly ServiceAccount/{SA_NAME}/{SA_NS}: {subs}")
    ref = rb["roleRef"]
    if ref.get("kind") != "Role" or roles.get((ns, ref.get("name"))) is None:
        errors.append(f"RoleBinding roleRef {ref} does not resolve to an existing Role in {ns}")

# Every Role/ClusterRole actually reachable by the ServiceAccount (via any RoleBinding or
# ClusterRoleBinding naming it, not just the ones this test already knows about) must never
# grant `secrets` or a `*` wildcard, in either resources or verbs.
bound_roles = {(rb["metadata"]["namespace"], rb["roleRef"]["name"])
               for rb in role_bindings
               if any(is_target_subject(s) for s in rb.get("subjects", [])) and rb["roleRef"]["kind"] == "Role"}
bound_cluster_roles = {rb["roleRef"]["name"] for rb in role_bindings
                        if any(is_target_subject(s) for s in rb.get("subjects", [])) and rb["roleRef"]["kind"] == "ClusterRole"}
bound_cluster_roles |= {crb["roleRef"]["name"] for crb in cluster_role_bindings
                         if any(is_target_subject(s) for s in crb.get("subjects", []))}

def check_wildcard(kind, key, rules):
    for rule in rules:
        res = set(rule.get("resources", []))
        vb = set(rule.get("verbs", []))
        if res & FORBIDDEN:
            errors.append(f"{kind} {key} grants forbidden resource(s) {sorted(res & FORBIDDEN)}")
        if vb & FORBIDDEN:
            errors.append(f"{kind} {key} grants forbidden verb(s) {sorted(vb & FORBIDDEN)}")

for ns, rname in bound_roles:
    r = roles.get((ns, rname))
    if r is None:
        errors.append(f"a RoleBinding references Role {ns}/{rname}, which does not exist")
        continue
    check_wildcard("Role", f"{ns}/{rname}", r["rules"])

for cname in bound_cluster_roles:
    cr = cluster_roles.get(cname)
    if cr is None:
        errors.append(f"a binding references ClusterRole {cname}, which does not exist")
        continue
    check_wildcard("ClusterRole", cname, cr["rules"])

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
PY
