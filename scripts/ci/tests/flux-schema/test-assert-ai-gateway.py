#!/usr/bin/env python3
"""Tests for assert-ai-gateway.py, the gate for AI-gateway invariants that span objects.

Every invariant here fails silently on a cluster. An unshared budget rule is a
valid BackendTrafficPolicy. A Gateway without the header strip still routes.
So each check is pinned both ways: the compliant shape passes, and each way
of breaking it fails with a message naming the object.

Run: python3 scripts/ci/tests/flux-schema/test-assert-ai-gateway.py
"""
import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
sys.path.insert(0, str(SUBJECT_DIR))
spec = importlib.util.spec_from_file_location("assert_ai_gateway", SUBJECT_DIR / "assert-ai-gateway.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAILURES = []
STRIPS = ["x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id"]


def check(name, condition, detail=""):
    if condition:
        print(f"  ok   {name}")
    else:
        print(f"  FAIL {name}{(' -- ' + detail) if detail else ''}")
        FAILURES.append(name)


def rule(**overrides):
    r = {
        "clientSelectors": [{"headers": [{"name": "x-ar-human", "type": "Distinct"}]}],
        "limit": {"requests": 10_000_000, "unit": "Day"},
        "cost": {
            "request": {"from": "Number", "number": 0},
            "response": {"from": "Metadata",
                         "metadata": {"namespace": "io.envoy.ai_gateway", "key": "llm_total_token"}},
        },
        "shared": True,
        "shadowMode": True,
    }
    r.update(overrides)
    return r


def btp(rules, name="ai-gateway-token-budgets", target=None):
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "BackendTrafficPolicy",
            "metadata": {"name": name, "namespace": "envoy-ai-gateway-system"},
            "spec": {"targetRefs": [target or {"group": "gateway.networking.k8s.io", "kind": "Gateway",
                                                "name": "ai-gateway"}],
                     "rateLimit": {"global": {"rules": rules}}}}


def gateway(name="ai-gateway", ns="envoy-ai-gateway-system", cls="envoy-ai-gateway", listeners=()):
    return {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "Gateway",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"gatewayClassName": cls, "listeners": [{"name": n} for n in listeners]}}


def ctp(remove, gw="ai-gateway", ns="envoy-ai-gateway-system", section=None):
    target = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        target["sectionName"] = section
    spec = {"targetRefs": [target]}
    if remove is not None:
        spec["headers"] = {"earlyRequestHeaders": {"remove": remove}}
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "ClientTrafficPolicy",
            "metadata": {"name": "client", "namespace": ns}, "spec": spec}


def mcproute(forward=None, gw="ai-gateway", ns="envoy-ai-gateway-system", parent_ns=None,
             claim_headers=None, client_id_header=None, api_key=None):
    parent = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if parent_ns:
        parent["namespace"] = parent_ns
    backend = {"name": "flux-operator-mcp", "port": 9090}
    if forward is not None:
        backend["forwardHeaders"] = [{"name": h} for h in forward]
    if api_key is not None:
        backend["securityPolicy"] = {"apiKey": {"secretRef": {"name": "key"}, **api_key}}
    route = {"apiVersion": "aigateway.envoyproxy.io/v1beta1", "kind": "MCPRoute",
             "metadata": {"name": "mcp", "namespace": ns},
             "spec": {"parentRefs": [parent], "backendRefs": [backend]}}
    security = {}
    if claim_headers is not None:
        security["oauth"] = {"claimToHeaders": [{"claim": "sub", "header": h} for h in claim_headers]}
    if client_id_header is not None:
        security["apiKeyAuth"] = {"forwardClientIDHeader": client_id_header}
    if security:
        route["spec"]["securityPolicy"] = security
    return route


def quiet(fn, *args):
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        return fn(*args)


print("A1/A2 — budget rules")
check("compliant rule passes", gate.check_rate_limit_rules([gateway(), btp([rule()])]) == [])
errs = gate.check_rate_limit_rules([gateway(), btp([rule(shared=False)])])
check("shared: false fails, naming the policy",
      len(errs) == 1 and "shared" in errs[0] and "ai-gateway-token-budgets" in errs[0], str(errs))
no_shared = rule()
del no_shared["shared"]
check("absent shared fails (Envoy Gateway defaults it to false)",
      len(gate.check_rate_limit_rules([gateway(), btp([no_shared])])) == 1)
errs = gate.check_rate_limit_rules([gateway(), btp([rule(cost={"request": {"from": "Number", "number": 1},
                                                     "response": rule()["cost"]["response"]})])])
check("request cost 1 fails", len(errs) == 1 and "request cost" in errs[0], str(errs))
wrong_key = rule()
wrong_key["cost"]["response"]["metadata"]["key"] = "llm_input_token"
errs = gate.check_rate_limit_rules([gateway(), btp([wrong_key])])
check("response cost from another key fails", len(errs) == 1 and "response cost" in errs[0], str(errs))
no_cost = rule()
del no_cost["cost"]
check("a rule with no cost fails (it would count calls, not tokens)",
      len(gate.check_rate_limit_rules([gateway(), btp([no_cost])])) == 2)
errs = gate.check_rate_limit_rules([gateway(), btp([rule(shadowMode=False)])])
check("shadowMode: false fails", len(errs) == 1 and "shadowMode" in errs[0], str(errs))
no_shadow = rule()
del no_shadow["shadowMode"]
check("absent shadowMode fails (OD-10 requires one week in shadow)",
      len(gate.check_rate_limit_rules([gateway(), btp([no_shadow])])) == 1)
local_only = btp([])
local_only["spec"]["rateLimit"] = {"local": {"rules": [{"limit": {"requests": 5, "unit": "Second"}}]}}
check("a local-only rate limit is out of scope",
      gate.check_rate_limit_rules([gateway(), btp([rule()]), local_only]) == [])

print("A1/A2 scope — only BackendTrafficPolicies targeting an envoy-ai-gateway Gateway count")
check("zero BackendTrafficPolicy targeting the Gateway fails, not passes vacuously",
      len(gate.check_rate_limit_rules([gateway()])) == 1)
errs = gate.check_rate_limit_rules([gateway(cls="cilium"), btp([rule(shared=False)])])
check("a rate limit on a non-ai-gateway Gateway is out of scope, and does not satisfy the guard either",
      len(errs) == 1 and "shared" not in errs[0], str(errs))
other_gw = gateway(name="other-gw", cls="cilium")
other_btp = btp([rule(shared=False)], name="other-gw-policy",
                 target={"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": "other-gw"})
check("that out-of-scope policy stays out of scope alongside a compliant ai-gateway one",
      gate.check_rate_limit_rules([gateway(), btp([rule()]), other_gw, other_btp]) == [])
route_only_target = {"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "harbor"}
# mergeType is set on both so A4 stays silent and isolates the A1/A2 scope question.
route_only = btp([rule(shared=False)], name="route-only-rl", target=route_only_target)
route_only["spec"]["mergeType"] = "Merge"
check("a BackendTrafficPolicy with no Gateway targetRef at all is out of scope for A1/A2",
      gate.check_rate_limit_rules([gateway(), btp([rule()]), route_only]) == [])
route_only_covers = btp([rule()], name="route-only-compliant", target=route_only_target)
route_only_covers["spec"]["mergeType"] = "Merge"
errs = gate.check_rate_limit_rules([gateway(), route_only_covers])
check("a route-only BackendTrafficPolicy does not satisfy the vacuous-pass guard either",
      len(errs) == 1 and "no BackendTrafficPolicy" in errs[0], str(errs))

print("A4 — a route-level BackendTrafficPolicy must declare mergeType")
route_target = {"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "llm-gateway"}
no_merge = btp([], name="route-btp", target=route_target)
errs = gate.check_rate_limit_rules([gateway(), btp([rule()]), no_merge])
check("an HTTPRoute-targeting policy without mergeType fails",
      len(errs) == 1 and "mergeType" in errs[0], str(errs))
with_merge = dict(no_merge)
with_merge["spec"] = dict(no_merge["spec"])
with_merge["spec"]["mergeType"] = "Merge"
check("the same policy with mergeType set passes",
      gate.check_rate_limit_rules([gateway(), btp([rule()]), with_merge]) == [])
aigw_route_target = {"group": "aigateway.envoyproxy.io", "kind": "AIGatewayRoute", "name": "llm-gateway"}
no_merge_aigw = btp([], name="aigw-route-btp", target=aigw_route_target)
check("an AIGatewayRoute-targeting policy without mergeType fails too",
      len(gate.check_rate_limit_rules([gateway(), btp([rule()]), no_merge_aigw])) == 1)

print("A3 — identity headers stripped before authentication")
check("full strip passes", gate.check_identity_strips([gateway(), ctp(STRIPS)]) == [])
errs = gate.check_identity_strips([gateway(), ctp(STRIPS[:-1])])
check("one header missing fails, naming it", len(errs) == 1 and "agent-session-id" in errs[0], str(errs))
check("no ClientTrafficPolicy fails", len(gate.check_identity_strips([gateway()])) == 1)
check("a policy in another namespace does not count",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, ns="other")])) == 1)
errs = gate.check_identity_strips([gateway(listeners=["public", "internal"]), ctp(STRIPS, section="public")])
check("a listener-scoped policy covers its own listener only (M6): the other one is reported",
      len(errs) == 1 and errs[0].endswith("covers listener(s) internal"), str(errs))
check("listener-scoped policies covering every listener satisfy the Gateway",
      gate.check_identity_strips([gateway(listeners=["public", "internal"]), ctp(STRIPS, section="public"),
                                  ctp(STRIPS, section="internal")]) == [])
check("a listener-scoped policy on a Gateway that declares no listener covers nothing",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, section="public")])) == 1)
errs = gate.check_identity_strips([gateway(), ctp(STRIPS), ctp(None, section="http")])
check("a listener-scoped override with no header strip fails even though the Gateway baseline is compliant",
      len(errs) == 1, str(errs))
check("header names are case-insensitive",
      gate.check_identity_strips([gateway(), ctp([h.upper() for h in STRIPS])]) == [])
check("other GatewayClasses are out of scope, alongside a compliant envoy-ai-gateway one",
      gate.check_identity_strips([gateway(cls="cilium"), gateway(), ctp(STRIPS)]) == [])
errs = gate.check_identity_strips([])
check("zero envoy-ai-gateway Gateways in the bundle fails, not passes vacuously",
      len(errs) == 1 and "no Gateway of class" in errs[0], str(errs))
check("a bundle with only a different-class Gateway also fails",
      len(gate.check_identity_strips([gateway(cls="cilium")])) == 1)

print("A5 — agent-router routes pin a listener, and route-level SecurityPolicies merge")


def route(kind="AIGatewayRoute", name="agent-models", section="public", gw="agent-router", ns="agent-system",
          parent_ns=None):
    parent = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        parent["sectionName"] = section
    if parent_ns:
        parent["namespace"] = parent_ns
    return {"kind": kind, "metadata": {"name": name, "namespace": ns}, "spec": {"parentRefs": [parent]}}


def secpol(target_kind="HTTPRoute", target_name="agent-models", merge=None, ns="agent-system", selector=False):
    spec = {}
    if selector:
        spec["targetSelectors"] = [{"group": "gateway.networking.k8s.io", "kind": target_kind,
                                    "matchLabels": {"app": "x"}}]
    else:
        spec["targetRefs"] = [{"group": "gateway.networking.k8s.io", "kind": target_kind, "name": target_name}]
    if merge:
        spec["mergeType"] = merge
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "SecurityPolicy",
            "metadata": {"name": "route-auth", "namespace": ns}, "spec": spec}


LISTENER_POLICY = secpol(target_kind="Gateway", target_name="agent-router")
check("a pinned route with a listener-scoped SecurityPolicy passes",
      gate.check_agent_router_routes([route(), LISTENER_POLICY]) == [])
for kind in ("AIGatewayRoute", "HTTPRoute", "GRPCRoute", "MCPRoute"):
    errs = gate.check_agent_router_routes([route(kind=kind, section=None)])
    check(f"{kind} on agent-router without sectionName fails (it attaches to every listener)",
          len(errs) == 1 and "sectionName" in errs[0] and kind in errs[0], str(errs))
check("an explicit parentRef namespace still counts",
      len(gate.check_agent_router_routes([route(section=None, ns="other", parent_ns="agent-system")])) == 1)
check("ai-gateway routes may omit sectionName (out of scope)",
      gate.check_agent_router_routes([route(), route(name="llm-gateway", section=None, gw="ai-gateway",
                                                     ns="envoy-ai-gateway-system")]) == [])
check("a same-named Gateway in another namespace is out of scope",
      gate.check_agent_router_routes([route(), route(name="x", section=None, ns="other")]) == [])
errs = gate.check_agent_router_routes([route(), secpol()])
check("a SecurityPolicy on an agent-router route without mergeType fails (it replaces the listener's JWT)",
      len(errs) == 1 and "mergeType" in errs[0] and "route-auth" in errs[0], str(errs))
check("the same policy with mergeType passes",
      gate.check_agent_router_routes([route(), secpol(merge="JSONMerge")]) == [])
check("a policy on a route this bundle cannot resolve (an MCPRoute's generated HTTPRoute) is in scope",
      len(gate.check_agent_router_routes([route(), secpol(target_name="ai-eg-mcp-main-flux")])) == 1)
check("a policy selecting routes by label is in scope",
      len(gate.check_agent_router_routes([route(), secpol(selector=True)])) == 1)
check("a policy on a route of another Gateway is out of scope",
      gate.check_agent_router_routes([route(), route(kind="HTTPRoute", name="other", gw="ai-gateway"),
                                      secpol(target_name="other")]) == [])
check("a policy in another namespace is out of scope (targetRefs are namespace-local)",
      gate.check_agent_router_routes([route(), secpol(ns="other")]) == [])
errs = gate.check_agent_router_routes([LISTENER_POLICY])
check("zero routes on agent-router fails, not passes vacuously",
      len(errs) == 1 and "no route attaches" in errs[0], str(errs))

print("A6 — no MCPRoute hands the run's token to an MCP server")
check("an MCPRoute forwarding nothing passes", gate.check_mcp_token_passthrough([gateway(), mcproute()]) == [])
check("forwarding another header passes",
      gate.check_mcp_token_passthrough([gateway(), mcproute(["x-ar-agent"])]) == [])
errs = gate.check_mcp_token_passthrough([gateway(), mcproute(["Authorization"])])
check("forwarding Authorization fails, naming the route and backend",
      len(errs) == 1 and "MCPRoute" in errs[0] and "flux-operator-mcp" in errs[0], str(errs))
check("the header name is case-insensitive",
      len(gate.check_mcp_token_passthrough([gateway(), mcproute(["authorization"])])) == 1)
check("an oauth.claimToHeaders entry naming another header passes",
      gate.check_mcp_token_passthrough([gateway(), mcproute(claim_headers=["x-ar-agent"])]) == [])
errs = gate.check_mcp_token_passthrough([gateway(), mcproute(claim_headers=["Authorization"])])
check("an oauth.claimToHeaders entry naming Authorization fails, naming the route",
      len(errs) == 1 and "MCPRoute" in errs[0], str(errs))
check("claimToHeaders naming authorization is case-insensitive",
      len(gate.check_mcp_token_passthrough([gateway(), mcproute(claim_headers=["authorization"])])) == 1)
check("apiKeyAuth.forwardClientIDHeader naming another header passes",
      gate.check_mcp_token_passthrough([gateway(), mcproute(client_id_header="x-client-id")]) == [])
errs = gate.check_mcp_token_passthrough([gateway(), mcproute(client_id_header="Authorization")])
check("apiKeyAuth.forwardClientIDHeader naming Authorization fails, naming the route",
      len(errs) == 1 and "MCPRoute" in errs[0], str(errs))
check("forwardClientIDHeader naming authorization is case-insensitive",
      len(gate.check_mcp_token_passthrough([gateway(), mcproute(client_id_header="authorization")])) == 1)
check("a backend apiKey injected in another header passes",
      gate.check_mcp_token_passthrough([gateway(), mcproute(api_key={"header": "x-room-mcp-key"})]) == [])
check("a backend apiKey injected as a queryParam passes",
      gate.check_mcp_token_passthrough([gateway(), mcproute(api_key={"queryParam": "key"})]) == [])
errs = gate.check_mcp_token_passthrough([gateway(), mcproute(api_key={})])
check("a backend apiKey with no header (defaults to Authorization: Bearer) fails, naming the backend",
      len(errs) == 1 and "flux-operator-mcp" in errs[0] and "apiKey" in errs[0], str(errs))
check("a backend apiKey header naming Authorization fails, case-insensitively",
      len(gate.check_mcp_token_passthrough([gateway(), mcproute(api_key={"header": "AUTHORIZATION"})])) == 1)
check("an explicit parentRef namespace resolves the same Gateway",
      len(gate.check_mcp_token_passthrough(
          [gateway(), mcproute(["Authorization"], ns="other", parent_ns="envoy-ai-gateway-system")])) == 1)
errs = gate.check_mcp_token_passthrough([gateway(), mcproute(["Authorization"], ns="other")])
check("an MCPRoute whose parentRef resolves to another namespace is out of scope, and does not satisfy the guard",
      len(errs) == 1 and "no MCPRoute" in errs[0], str(errs))
errs = gate.check_mcp_token_passthrough([gateway(), gateway(name="cilium-gw", cls="cilium"),
                                         mcproute(["Authorization"], gw="cilium-gw")])
check("an MCPRoute on another GatewayClass is out of scope, and does not satisfy the guard",
      len(errs) == 1 and "no MCPRoute" in errs[0], str(errs))
errs = gate.check_mcp_token_passthrough([gateway()])
check("zero MCPRoutes on an envoy-ai-gateway Gateway fails, not passes vacuously",
      len(errs) == 1 and "no MCPRoute" in errs[0], str(errs))


def models_guard_route(name="agent-models-list", section="public", gw="agent-router", ns="agent-system",
                        path_type="Exact", path_value="/v1/models", filter_name="agent-models-list",
                        filter_kind="HTTPRouteFilter"):
    parent = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        parent["sectionName"] = section
    return {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "HTTPRoute",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"parentRefs": [parent],
                     "rules": [{"matches": [{"path": {"type": path_type, "value": path_value}}],
                                "filters": [{"type": "ExtensionRef",
                                            "extensionRef": {"group": "gateway.envoyproxy.io",
                                                              "kind": filter_kind, "name": filter_name}}]}]}}


def models_guard_filter(name="agent-models-list", ns="agent-system", direct_response=True):
    spec = {"directResponse": {"statusCode": 404}} if direct_response else {}
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "HTTPRouteFilter",
            "metadata": {"name": name, "namespace": ns}, "spec": spec}


print("A7 -- /v1/models guard route on every agent-router listener an AIGatewayRoute attaches to")
check("the guard present passes",
      gate.check_v1_models_guard([route(), models_guard_route(), models_guard_filter()]) == [])
errs = gate.check_v1_models_guard([route()])
check("the guard missing fails, naming the listener",
      len(errs) == 1 and "public" in errs[0], str(errs))
errs = gate.check_v1_models_guard([route(), models_guard_route(section="internal"), models_guard_filter()])
check("the guard on the wrong sectionName fails",
      len(errs) == 1 and "public" in errs[0], str(errs))
errs = gate.check_v1_models_guard([route(), models_guard_route(path_type="PathPrefix"), models_guard_filter()])
check("a path prefix instead of Exact fails", len(errs) == 1, str(errs))
errs = gate.check_v1_models_guard([route(), models_guard_route(), models_guard_filter(direct_response=False)])
check("a filter with no directResponse fails", len(errs) == 1, str(errs))
errs = gate.check_v1_models_guard([])
check("no AIGatewayRoute on agent-router fails, not passes vacuously",
      len(errs) == 1 and "no AIGatewayRoute attaches" in errs[0], str(errs))

print("main()")
with tempfile.TemporaryDirectory() as d:
    p = pathlib.Path(d)
    (p / "overlay-a.yaml").write_text(yaml.safe_dump_all(
        [gateway(), ctp(STRIPS), btp([rule()]), route(), mcproute(), models_guard_route(), models_guard_filter()]))
    check("exit 0 on a compliant bundle", quiet(gate.main, [d]) == 0)
    (p / "overlay-b.yaml").write_text(yaml.safe_dump_all([btp([rule(shared=False)], name="bad")]))
    check("exit 1 on a violation", quiet(gate.main, [d]) == 1)
check("exit 2 when the bundle is missing", quiet(gate.main, ["/nonexistent-bundle-dir"]) == 2)

if FAILURES:
    print(f"\n{len(FAILURES)} failed")
    sys.exit(1)
print("\nall passed")
