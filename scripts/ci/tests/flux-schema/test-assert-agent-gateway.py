#!/usr/bin/env python3
"""Tests for assert-agent-gateway.py, the agentgateway agent router's cross-object gate.

Each invariant is pinned both ways: the compliant bundle passes, and each way of
breaking it fails with a message naming the check.

Run: python3 scripts/ci/tests/flux-schema/test-assert-agent-gateway.py
"""
import contextlib
import copy
import importlib.util
import io
import pathlib
import sys
import tempfile

import yaml

HERE = pathlib.Path(__file__).resolve().parent
SUBJECT_DIR = HERE.parent.parent / "flux-schema"
sys.path.insert(0, str(SUBJECT_DIR))
spec = importlib.util.spec_from_file_location("assert_agent_gateway", SUBJECT_DIR / "assert-agent-gateway.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

FAILURES = []
REAL = ("agent-gateway", "agent-router")
POC = ("agw-poc", "agent-router-agw")


def check(name, condition, detail=""):
    print(f"  {'ok  ' if condition else 'FAIL'} {name}{'' if condition or not detail else ' -- ' + detail}")
    if not condition:
        FAILURES.append(name)


def obj(kind, ns, name, spec, api="agentgateway.dev/v1alpha1"):
    return {"apiVersion": api, "kind": kind, "metadata": {"namespace": ns, "name": name}, "spec": spec}


def compliant(key=REAL):
    gw_ns, gw_name = key
    prof = gate.PROFILES[key]
    rns = prof.routes_ns
    gw_ref = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw_name}

    def listener_policy(section):
        jwt = {"mode": "Strict", "providers": [{
            "issuer": "https://issuer.example", "audiences": sorted(gate.audiences(prof, section)),
            "jwks": {"remote": {"url": "https://issuer.example/jwks"}},
            "validation": {"requiredClaims": ["exp", "sub"]}}]}
        if section == "sts":
            jwt["preserveToken"] = True
        return obj("AgentgatewayPolicy", gw_ns, f"listener-{section}", {
            "targetRefs": [dict(gw_ref, sectionName=section)],
            "traffic": {"jwtAuthentication": jwt,
                        "authorization": {"action": "Require",
                                          "policy": {"matchExpressions": [gate.sub_prefix(prof)]}},
                        "transformation": {"request": {"set": [{"name": "x-ar-agent", "value": "jwt.sub"}]}}}})

    def route(name, section, rules):
        return obj("HTTPRoute", rns, name, {
            "parentRefs": [dict(gw_ref, namespace=gw_ns, sectionName=section)], "rules": rules},
            api="gateway.networking.k8s.io/v1")

    def backend_ref(name):
        return [{"group": "agentgateway.dev", "kind": "AgentgatewayBackend", "name": name, "namespace": "agent-system"}]

    selector = ({"from": "Same"} if rns == gw_ns else
                {"from": "Selector", "selector": {"matchLabels": {"kubernetes.io/metadata.name": rns}}})
    allow = f'"{prof.aud_prefix}.implementer.public" in jwt.aud && mcp.tool.target == "room-broker"'
    return [
        obj("Gateway", gw_ns, gw_name, {
            "gatewayClassName": "agentgateway",
            "listeners": [{"name": n, "port": p, "protocol": "HTTP", "allowedRoutes": {"namespaces": selector}}
                          for n, p in prof.listeners.items()],
            "infrastructure": {"parametersRef": {"group": "agentgateway.dev", "kind": "AgentgatewayParameters",
                                                 "name": gw_name}}}, api="gateway.networking.k8s.io/v1"),
        obj("AgentgatewayParameters", gw_ns, gw_name, {
            "image": {"digest": "sha256:" + "0" * 64}, "shutdown": {"min": 10, "max": 660},
            "resources": {"limits": {"cpu": "1", "memory": "1Gi"}},
            "service": {"spec": {"type": "ClusterIP"}}, "podDisruptionBudget": {"spec": {"minAvailable": 1}},
            "deployment": {"spec": {"replicas": 2, "template": {"spec": {
                "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "agentgateway",
                                "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
                                "livenessProbe": {"httpGet": {"path": "/healthz/ready", "port": 15021}}}]}}}}}),
        obj("AgentgatewayPolicy", gw_ns, "strip-identity-headers", {
            "targetRefs": [gw_ref],
            "traffic": {"phase": "PreRouting",
                        "transformation": {"request": {"remove": list(gate.IDENTITY_HEADERS)}}}}),
        *[listener_policy(s) for s in prof.listeners],
        obj("AgentgatewayBackend", "agent-system", "zai", {
            "ai": {"provider": {"custom": {"model": "glm-5.3", "formats": [
                {"type": "Completions", "path": "/api/paas/v4/chat/completions"}]},
                "host": "api.z.ai", "port": 443}},
            "policies": {"auth": {"secretRef": {"name": "zai-api-key", "key": "apiKey"}},
                         "ai": {"routes": {"/v1/chat/completions": "Completions", "/v1/messages": "Messages"}}}}),
        route("agent-models", "public", [
            {"name": "models", "matches": [{"path": {"type": "Exact", "value": "/v1/models"}}],
             "backendRefs": backend_ref("zai")},
            {"name": "openai", "matches": [{"path": {"type": "PathPrefix", "value": "/v1"}}],
             "backendRefs": backend_ref("zai")}]),
        obj("AgentgatewayPolicy", rns, "agent-models-list", {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "agent-models",
                            "sectionName": "models"}],
            "traffic": {"directResponse": {"status": 404, "body": '{"error":"model listing is not served"}'}}}),
        obj("AgentgatewayBackend", rns, "agent-mcp", {"mcp": {"sessionRouting": "Stateless", "targets": [
            {"name": "room-broker", "static": {
                "host": "room-broker.agent-system.svc.cluster.local", "port": 8090, "path": "/mcp",
                "protocol": "StreamableHTTP", "policies": {"auth": {"credentials": [
                    {"location": {"header": {"name": "x-room-mcp-key"}},
                     "secretRef": {"name": "room-broker-mcp-key", "key": "apiKey"}}]}}}}]}}),
        route("agent-mcp-public", "public", [{"matches": [{"path": {"type": "PathPrefix", "value": "/mcp"}}],
                                              "backendRefs": [{"group": "agentgateway.dev",
                                                               "kind": "AgentgatewayBackend", "name": "agent-mcp"}]}]),
        obj("AgentgatewayPolicy", rns, "agent-mcp-public", {
            "targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "HTTPRoute", "name": "agent-mcp-public"}],
            "backend": {"mcp": {"authorization": {"action": "Allow", "policy": {"matchExpressions": [
                allow + ' && mcp.tool.name in ["room_read", "room_post"]',
                allow + ' && mcp.tool.name == "room_read"']}}}}}),
        obj("AgentgatewayPolicy", gw_ns, "token-budgets", {
            "targetRefs": [gw_ref],
            "traffic": {"rateLimit": {
                "global": {
                    "backendRef": {"name": "agent-ratelimit", "port": 8081}, "domain": "agent-router",
                    "failureMode": "FailOpen", "descriptors": [
                        {"entries": [{"name": "agent", "expression": "jwt.sub"}], "unit": "Tokens",
                         "cost": gate.BILLABLE_COST},
                        {"entries": [{"name": "fleet", "expression": '"agents"'}], "unit": "Tokens",
                         "cost": gate.BILLABLE_COST}]},
                "local": [{"tokens": 30000000, "unit": "Hours", "key": "jwt.sub"}]}}}),
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"namespace": gw_ns, "name": "agent-ratelimit-config"},
         "data": {"config.yaml": yaml.safe_dump({"domain": "agent-router", "descriptors": [
             {"key": "agent", "rate_limit": {"unit": "day", "requests_per_unit": 5000000}, "shadow_mode": True},
             {"key": "fleet", "value": "agents", "rate_limit": {"unit": "day", "requests_per_unit": 40000000},
              "shadow_mode": True}]})}},
        {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": {"namespace": gw_ns, "name": "agent-ratelimit"},
         "spec": {"template": {"spec": {
             "containers": [{"name": "ratelimit", "env": [{"name": "SHADOW_MODE", "value": "true"}]}],
             "volumes": [{"name": "config", "configMap": {"name": "agent-ratelimit-config"}}]}}}},
    ]


def find(objs, kind, name):
    return next(o for o in objs if o["kind"] == kind and o["metadata"]["name"] == name)


def spec_at(objs, kind, name, *path):
    node = find(objs, kind, name)["spec"]
    for key in path:
        node = node[key]
    return node


def expect(name, mutate, code, needle=""):
    objs = copy.deepcopy(compliant())
    mutate(objs)
    v = gate.run(objs)
    check(name, any(x.startswith(code) and needle in x for x in v), f"got {v}")


def jwt_of(o, listener):
    return spec_at(o, "AgentgatewayPolicy", f"listener-{listener}", "traffic", "jwtAuthentication")


def zai(o):
    return find(o, "AgentgatewayBackend", "zai")["spec"]


def params(o):
    return spec_at(o, "AgentgatewayParameters", "agent-router")


print("compliant bundles")
got = gate.run(compliant(REAL))
check("compliant agent-gateway/agent-router passes", got == [], f"got {got}")
got = gate.run(compliant(REAL) + compliant(POC))
check("the PoC beside the real Gateway passes", got == [], f"got {got}")
check("eleven checks", len(gate.CHECKS) == 11, f"got {len(gate.CHECKS)}")

print("AG1 gateway")
expect("no Gateway fails", lambda o: o.remove(find(o, "Gateway", "agent-router")), "AG1")
expect("a dropped listener fails", lambda o: spec_at(o, "Gateway", "agent-router", "listeners").pop(), "AG1")
expect("routes from All fails", lambda o: spec_at(o, "Gateway", "agent-router", "listeners")[0]
       ["allowedRoutes"].update({"namespaces": {"from": "All"}}), "AG1")
got = gate.run(compliant(POC))
check("the PoC without the real Gateway fails AG1",
      any(v.startswith("AG1: required Gateway agent-gateway/agent-router") for v in got), f"got {got}")
expect("an unknown agentgateway Gateway fails", lambda o: o.append(
    obj("Gateway", "elsewhere", "shadow", {"gatewayClassName": "agentgateway", "listeners": []},
        api="gateway.networking.k8s.io/v1")), "AG1")

print("AG2 listener identity")
expect("a missing listener policy fails", lambda o: o.remove(find(o, "AgentgatewayPolicy", "listener-internal")), "AG2")
expect("an internal audience on public fails", lambda o: jwt_of(o, "public")["providers"][0]["audiences"]
       .append("agent-router.implementer.internal"), "AG2")
expect("Allow instead of Require fails", lambda o: spec_at(o, "AgentgatewayPolicy", "listener-public", "traffic",
                                                           "authorization").update({"action": "Allow"}), "AG2")
expect("no x-ar-agent set fails", lambda o: spec_at(o, "AgentgatewayPolicy", "listener-sts", "traffic")
       .pop("transformation"), "AG2")
expect("requiredClaims without sub fails", lambda o: jwt_of(o, "public")["providers"][0]["validation"]
       .update({"requiredClaims": ["exp"]}), "AG2")
expect("no validation (1.6 stores no default) fails", lambda o: jwt_of(o, "internal")["providers"][0]
       .pop("validation"), "AG2")

print("AG3 strip")
expect("a strip missing agent-session-id fails", lambda o: spec_at(
    o, "AgentgatewayPolicy", "strip-identity-headers", "traffic", "transformation", "request", "remove")
    .remove("agent-session-id"), "AG3")
expect("no PreRouting phase fails", lambda o: spec_at(o, "AgentgatewayPolicy", "strip-identity-headers", "traffic")
       .pop("phase"), "AG3")

print("AG4 token isolation")
expect("preserveToken on public fails", lambda o: jwt_of(o, "public").update({"preserveToken": True}), "AG4")
expect("no preserveToken on sts fails", lambda o: jwt_of(o, "sts").pop("preserveToken"), "AG4")
expect("an MCP key in Authorization fails", lambda o: spec_at(o, "AgentgatewayBackend", "agent-mcp", "mcp", "targets")[0]
       ["static"]["policies"]["auth"]["credentials"][0]["location"]["header"].update({"name": "Authorization"}), "AG4")
expect("auth.secretRef on an MCP target fails", lambda o: spec_at(o, "AgentgatewayBackend", "agent-mcp", "mcp", "targets")[0]
       ["static"]["policies"].update({"auth": {"secretRef": {"name": "k"}}}), "AG4")

print("AG5 routes and the Z.ai provider")
expect("no sectionName fails", lambda o: spec_at(o, "HTTPRoute", "agent-models", "parentRefs")[0].pop("sectionName"), "AG5")
expect("zai on internal fails", lambda o: spec_at(o, "HTTPRoute", "agent-models", "parentRefs")[0]
       .update({"sectionName": "internal"}), "AG5")
expect("route-level jwtAuthentication fails", lambda o: spec_at(o, "AgentgatewayPolicy", "agent-mcp-public")
       .update({"traffic": {"jwtAuthentication": {"mode": "Strict"}}}), "AG5")
expect("Z.ai on the openai provider fails", lambda o: zai(o)["ai"].update(
    {"provider": {"openai": {"model": "glm-5.3"}, "host": "api.z.ai", "port": 443, "path": "/api/paas/v4/chat/completions"}}), "AG5")


def rename_to_openai(o):
    b = find(o, "AgentgatewayBackend", "zai")
    b["metadata"]["name"] = "glm"
    provider = b["spec"]["ai"]["provider"]
    provider.pop("custom")
    provider.update({"openai": {}, "path": "/api/paas/v4/chat/completions"})


expect("a Z.ai backend found by host, not name, is judged", rename_to_openai, "AG5")

print("AG6 MCP authorization")


def add_expr(e):
    return lambda o: spec_at(o, "AgentgatewayPolicy", "agent-mcp-public", "backend", "mcp", "authorization", "policy",
                             "matchExpressions").append(e)


expect("a role-only expression fails", add_expr('"agent-router.reviewer.public" in jwt.aud'), "AG6")
expect("an || expression fails", add_expr('"agent-router.reviewer.public" in jwt.aud || mcp.tool.name == "room_post"'), "AG6")
expect("an internal audience on a public route fails", add_expr(
    '"agent-router.implementer.internal" in jwt.aud && mcp.tool.target == "room-broker" && mcp.tool.name in ["room_read"]'),
    "AG6")
expect("a Deny action fails", lambda o: spec_at(o, "AgentgatewayPolicy", "agent-mcp-public", "backend", "mcp",
                                                "authorization").update({"action": "Deny"}), "AG6")

print("AG7 /v1/models")
expect("no /v1/models answer fails", lambda o: o.remove(find(o, "AgentgatewayPolicy", "agent-models-list")), "AG7")
expect("a 404 on another rule fails", lambda o: spec_at(o, "AgentgatewayPolicy", "agent-models-list", "targetRefs")[0]
       .update({"sectionName": "openai"}), "AG7")

print("AG8 budgets")


def glob(o):
    return spec_at(o, "AgentgatewayPolicy", "token-budgets", "traffic", "rateLimit", "global")


def unshadow(o):
    cm = find(o, "ConfigMap", "agent-ratelimit-config")
    cfg = yaml.safe_load(cm["data"]["config.yaml"])
    cfg["descriptors"][0]["shadow_mode"] = False
    cm["data"]["config.yaml"] = yaml.safe_dump(cfg)


expect("FailClosed fails", lambda o: glob(o).update({"failureMode": "FailClosed"}), "AG8")
expect("no explicit failureMode fails", lambda o: glob(o).pop("failureMode"), "AG8")
expect("a request-unit descriptor fails", lambda o: glob(o)["descriptors"][0].update({"unit": "Requests"}), "AG8")
expect("a route-keyed entry fails", lambda o: glob(o)["descriptors"][0]["entries"].append(
    {"name": "route", "expression": "request.path"}), "AG8")
expect("an enforcing descriptor fails", unshadow, "AG8")
expect("a missing ConfigMap fails", lambda o: o.remove(find(o, "ConfigMap", "agent-ratelimit-config")), "AG8")


def server_env(o):
    return find(o, "Deployment", "agent-ratelimit")["spec"]["template"]["spec"]["containers"][0]["env"]


def local(o):
    return spec_at(o, "AgentgatewayPolicy", "token-budgets", "traffic", "rateLimit", "local")


print("AG8 shadow on the server (no budget 429 while any descriptor could enforce)")
expect("a server without SHADOW_MODE fails", lambda o: server_env(o).clear(), "AG8", "SHADOW_MODE")
expect("SHADOW_MODE false fails", lambda o: server_env(o)[0].update({"value": "false"}), "AG8", "SHADOW_MODE")
expect("no server reading the ConfigMap fails", lambda o: o.remove(find(o, "Deployment", "agent-ratelimit")),
       "AG8", "SHADOW_MODE")

print("AG8 reference tokens (design D11, OD-6)")
expect("a Tokens descriptor without cost fails", lambda o: glob(o)["descriptors"][0].pop("cost"), "AG8",
       "reference tokens")
expect("a raw-token cost fails", lambda o: glob(o)["descriptors"][1].update({"cost": "llm.totalTokens"}), "AG8",
       "reference tokens")

print("AG8 required claims (#3523: a descriptor whose CEL fails is dropped, unlimited)")
expect("a descriptor reading an unrequired claim fails",
       lambda o: glob(o)["descriptors"][0]["entries"][0].update({"expression": "jwt.team"}), "AG8", "#3523")
expect("a descriptor reading a bracketed unrequired claim fails",
       lambda o: glob(o)["descriptors"][0]["entries"][0].update({"expression": 'jwt["team"]'}), "AG8", "#3523")
expect("a descriptor reading a header fails",
       lambda o: glob(o)["descriptors"][0]["entries"][0].update({"expression": 'request.headers["x-ar-agent"]'}),
       "AG8", "#3523")
expect("sub no longer required on one listener fails",
       lambda o: jwt_of(o, "sts")["providers"][0]["validation"].update({"requiredClaims": ["exp"]}), "AG8", "#3523")
expect("an unkeyed local token limit fails", lambda o: local(o)[0].pop("key"), "AG8", "key")
expect("a local key reading an unrequired claim fails", lambda o: local(o)[0].update({"key": "jwt.team"}),
       "AG8", "#3523")
got = gate.run([o if o["kind"] != "AgentgatewayPolicy" or o["metadata"]["name"] != "token-budgets" else
                {**o, "spec": {**o["spec"], "traffic": {"rateLimit": {**o["spec"]["traffic"]["rateLimit"], "global": {
                    **o["spec"]["traffic"]["rateLimit"]["global"], "descriptors": [
                        {"entries": [{"name": "agent", "expression": 'jwt["sub"].lowerAscii()'}], "unit": "Tokens",
                         "cost": gate.BILLABLE_COST}]}}}}}
                for o in compliant()])
check("a required claim read with a method call passes", got == [], f"got {got}")

print("AG9 parameters")
expect("a LoadBalancer Service fails", lambda o: params(o)["service"]["spec"].update({"type": "LoadBalancer"}), "AG9")
expect("the default drain fails", lambda o: params(o).update({"shutdown": {"min": 10, "max": 60}}), "AG9")
expect("N1's old min 120 fails", lambda o: params(o).update({"shutdown": {"min": 120, "max": 660}}), "AG9")
expect("no shutdown (1.6 stores no default) fails", lambda o: params(o).pop("shutdown"), "AG9")
expect("no liveness probe fails", lambda o: params(o)["deployment"]["spec"]["template"]["spec"]["containers"][0]
       .pop("livenessProbe"), "AG9")
expect("a tag-only image fails", lambda o: params(o).update({"image": {"tag": "v1.6.0"}}), "AG9")

print("AG11 provider paths")
expect("a custom format without a path fails", lambda o: zai(o)["ai"]["provider"]["custom"]["formats"][0].pop("path"), "AG11")
expect("a host-overridden openai provider without a path fails", lambda o: o.append(obj(
    "AgentgatewayBackend", "agent-system", "proxy", {"ai": {"provider": {"openai": {}, "host": "llm.example", "port": 443}}})),
    "AG11")
expect("a Z.ai Detect route fails", lambda o: zai(o)["policies"]["ai"]["routes"].update({"/v1": "Detect"}), "AG11")
expect("a Z.ai Passthrough route fails", lambda o: zai(o)["policies"]["ai"]["routes"].update({"/v1/x": "Passthrough"}), "AG11")
expect("a Z.ai backend without typed routes fails", lambda o: zai(o)["policies"].pop("ai"), "AG11")


def run_main(d):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = gate.main(["x", d])
    return code, out.getvalue() + err.getvalue()


print("main")
with tempfile.TemporaryDirectory() as d:
    # base and both clusters render the same objects: one world per cluster, so no double count.
    for name in ("overlay-infrastructure-base-agent-gateway.yaml", "overlay-infrastructure-aws-0-agent-gateway.yaml",
                 "overlay-infrastructure-gcp-0-agent-gateway.yaml"):
        pathlib.Path(d, name).write_text(yaml.safe_dump_all(compliant()))
    code, out = run_main(d)
    check("main exits 0 on per-cluster duplicates", code == 0, out)
    check("main prints 11 checks", "assert-agent-gateway: 11 checks, 0 violations" in out, out)
    pathlib.Path(d, "overlay-infrastructure-gcp-0-agent-gateway.yaml").write_text(
        yaml.safe_dump_all([o for o in compliant() if o["kind"] != "Gateway"]))
    code, out = run_main(d)
    check("a cluster with agentgateway objects but no Gateway fails AG1", code == 1 and "AG1" in out, out)
with tempfile.TemporaryDirectory() as d:
    pathlib.Path(d, "overlay-infrastructure-aws-0-other.yaml").write_text(
        yaml.safe_dump({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "x", "namespace": "y"}}))
    code, out = run_main(d)
    check("no agentgateway object fails, not passes", code == 1 and "AG1" in out, out)
    check("main exits 2 on a missing bundle", run_main(d + "/missing")[0] == 2)

if FAILURES:
    print(f"\n{len(FAILURES)} failure(s)")
    sys.exit(1)
print("\nall passed")
