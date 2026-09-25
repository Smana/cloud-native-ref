#!/usr/bin/env python3
"""Tests for assert-ai-gateway.py, the gate for AI-gateway invariants that span objects.

Every invariant here fails silently on a cluster. An unshared budget rule is a
valid BackendTrafficPolicy. A Gateway without the header strip still routes. A
Z.ai route on the wrong listener still answers. So each check is pinned both
ways: the compliant shape passes, and each way of breaking it fails with a
message naming the object.

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


def btp(rules, name="ai-gateway-token-budgets"):
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "BackendTrafficPolicy",
            "metadata": {"name": name, "namespace": "envoy-ai-gateway-system"},
            "spec": {"targetRefs": [{"group": "gateway.networking.k8s.io", "kind": "Gateway",
                                     "name": "ai-gateway"}],
                     "rateLimit": {"global": {"rules": rules}}}}


def gateway(name="ai-gateway", ns="envoy-ai-gateway-system", cls="envoy-ai-gateway"):
    return {"apiVersion": "gateway.networking.k8s.io/v1", "kind": "Gateway",
            "metadata": {"name": name, "namespace": ns},
            "spec": {"gatewayClassName": cls, "listeners": []}}


def ctp(remove, gw="ai-gateway", ns="envoy-ai-gateway-system", section=None):
    target = {"group": "gateway.networking.k8s.io", "kind": "Gateway", "name": gw}
    if section:
        target["sectionName"] = section
    spec = {"targetRefs": [target]}
    if remove is not None:
        spec["headers"] = {"earlyRequestHeaders": {"remove": remove}}
    return {"apiVersion": "gateway.envoyproxy.io/v1alpha1", "kind": "ClientTrafficPolicy",
            "metadata": {"name": "client", "namespace": ns}, "spec": spec}


def quiet(fn, *args):
    with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
        return fn(*args)


print("A1/A2 — budget rules")
check("compliant rule passes", gate.check_rate_limit_rules([btp([rule()])]) == [])
errs = gate.check_rate_limit_rules([btp([rule(shared=False)])])
check("shared: false fails, naming the policy",
      len(errs) == 1 and "shared" in errs[0] and "ai-gateway-token-budgets" in errs[0], str(errs))
no_shared = rule()
del no_shared["shared"]
check("absent shared fails (Envoy Gateway defaults it to false)",
      len(gate.check_rate_limit_rules([btp([no_shared])])) == 1)
errs = gate.check_rate_limit_rules([btp([rule(cost={"request": {"from": "Number", "number": 1},
                                                     "response": rule()["cost"]["response"]})])])
check("request cost 1 fails", len(errs) == 1 and "request cost" in errs[0], str(errs))
wrong_key = rule()
wrong_key["cost"]["response"]["metadata"]["key"] = "llm_input_token"
errs = gate.check_rate_limit_rules([btp([wrong_key])])
check("response cost from another key fails", len(errs) == 1 and "response cost" in errs[0], str(errs))
no_cost = rule()
del no_cost["cost"]
check("a rule with no cost fails (it would count calls, not tokens)",
      len(gate.check_rate_limit_rules([btp([no_cost])])) == 2)
errs = gate.check_rate_limit_rules([btp([rule(shadowMode=False)])])
check("shadowMode: false fails", len(errs) == 1 and "shadowMode" in errs[0], str(errs))
no_shadow = rule()
del no_shadow["shadowMode"]
check("absent shadowMode fails (OD-10 requires one week in shadow)",
      len(gate.check_rate_limit_rules([btp([no_shadow])])) == 1)
local_only = btp([])
local_only["spec"]["rateLimit"] = {"local": {"rules": [{"limit": {"requests": 5, "unit": "Second"}}]}}
check("a local-only rate limit is out of scope", gate.check_rate_limit_rules([local_only]) == [])

print("A3 — identity headers stripped before authentication")
check("full strip passes", gate.check_identity_strips([gateway(), ctp(STRIPS)]) == [])
errs = gate.check_identity_strips([gateway(), ctp(STRIPS[:-1])])
check("one header missing fails, naming it", len(errs) == 1 and "agent-session-id" in errs[0], str(errs))
check("no ClientTrafficPolicy fails", len(gate.check_identity_strips([gateway()])) == 1)
check("a policy in another namespace does not count",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, ns="other")])) == 1)
check("a listener-scoped policy does not cover the whole Gateway",
      len(gate.check_identity_strips([gateway(), ctp(STRIPS, section="http")])) == 1)
check("header names are case-insensitive",
      gate.check_identity_strips([gateway(), ctp([h.upper() for h in STRIPS])]) == [])
check("other GatewayClasses are out of scope, alongside a compliant envoy-ai-gateway one",
      gate.check_identity_strips([gateway(cls="cilium"), gateway(), ctp(STRIPS)]) == [])
errs = gate.check_identity_strips([])
check("zero envoy-ai-gateway Gateways in the bundle fails, not passes vacuously",
      len(errs) == 1 and "no Gateway of class" in errs[0], str(errs))
check("a bundle with only a different-class Gateway also fails",
      len(gate.check_identity_strips([gateway(cls="cilium")])) == 1)

print("main()")
with tempfile.TemporaryDirectory() as d:
    p = pathlib.Path(d)
    (p / "overlay-a.yaml").write_text(yaml.safe_dump_all([gateway(), ctp(STRIPS), btp([rule()])]))
    check("exit 0 on a compliant bundle", quiet(gate.main, [d]) == 0)
    (p / "overlay-b.yaml").write_text(yaml.safe_dump_all([btp([rule(shared=False)], name="bad")]))
    check("exit 1 on a violation", quiet(gate.main, [d]) == 1)
check("exit 2 when the bundle is missing", quiet(gate.main, ["/nonexistent-bundle-dir"]) == 2)

if FAILURES:
    print(f"\n{len(FAILURES)} failed")
    sys.exit(1)
print("\nall passed")
