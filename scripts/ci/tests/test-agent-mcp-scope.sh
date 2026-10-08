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

# --- MCPRoutes: exact tool sets, not a denylist of three introspection names ---

VM_TOOLS = {"documentation", "query", "query_range", "metrics", "metrics_metadata", "labels",
            "label_values", "series", "alerts", "rules", "explain_query", "prettify_query",
            "metric_statistics"}
VL_TOOLS = {"documentation", "query", "hits", "facets", "field_names", "field_values",
            "stats_query", "stats_query_range", "streams", "stream_ids", "stream_field_names",
            "stream_field_values"}

# SP2 §3: the same room tools on both listeners; room_handoff is not a reviewer's,
# room_verdict is not an implementer's or a triager's.
ROOM_TOOLS = {"room_read", "room_post", "room_handoff", "room_verdict"}
ROOM_GRANTS = {
    "implementer": {"room_read", "room_post", "room_handoff"},
    "reviewer": {"room_read", "room_post", "room_verdict"},
    "tester": ROOM_TOOLS,
    "triager": {"room_read", "room_post", "room_handoff"},
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

for route in yaml.safe_load_all(open(os.path.join(base, "mcproutes.yaml"))):
    if not route or route.get("kind") != "MCPRoute":
        continue
    name = route["metadata"]["name"]

    backend_expected = EXPECTED_BACKEND_TOOLS.get(name, {})
    seen_backends = set()
    for backend in route["spec"]["backendRefs"]:
        bname = backend["name"]
        seen_backends.add(bname)
        got = set((backend.get("toolSelector") or {}).get("include") or [])
        want = backend_expected.get(bname)
        if want is None:
            errors.append(f"{name}: unexpected backend {bname}")
        elif got != want:
            errors.append(f"{name}: backend {bname} toolSelector is {sorted(got)}, expected {sorted(want)}")
    if set(backend_expected) - seen_backends:
        errors.append(f"{name}: missing expected backend(s) {sorted(set(backend_expected) - seen_backends)}")

    got_role_tools = {}
    for rule in route["spec"]["securityPolicy"]["authorization"]["rules"]:
        auds = {v for c in rule["source"]["jwt"]["claims"] for v in c["values"]}
        for aud in auds:
            for t in rule["target"]["tools"]:
                got_role_tools.setdefault(aud, {}).setdefault(t["backend"], set()).add(t["tool"])

    role_expected = EXPECTED_ROLE_TOOLS.get(name, {})
    for aud, backends_expected in role_expected.items():
        got_backends = got_role_tools.get(aud, {})
        for bname, want in backends_expected.items():
            got = got_backends.get(bname, set())
            if got != want:
                errors.append(f"{name}: {aud} backend {bname} tools are {sorted(got)}, expected {sorted(want)}")
        extra = set(got_backends) - set(backends_expected)
        if extra:
            errors.append(f"{name}: {aud} grants unexpected backend(s) {sorted(extra)}")
    extra_auds = set(got_role_tools) - set(role_expected)
    if extra_auds:
        errors.append(f"{name}: unexpected audience(s) with grants {sorted(extra_auds)}")

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
