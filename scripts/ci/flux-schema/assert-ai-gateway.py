#!/usr/bin/env python3
"""Gate the rendered bundle on AI-gateway invariants that span objects.

`flux schema validate` checks each object alone. These rules relate objects,
and breaking any of them leaves every object valid and the gateway quietly
wrong:

  A1  Every global rate-limit rule sets `shared: true`. The default gives every
      route its own bucket, multiplying each budget by the number of routes a
      principal can reach (programme contract C5).
  A2  Every such rule charges tokens, not calls: request cost 0, response cost
      from io.envoy.ai_gateway/llm_total_token (SP4 design section 6).
  A3  Every Gateway of class envoy-ai-gateway is covered by a whole-Gateway
      ClientTrafficPolicy that removes the identity headers before
      authentication. Envoy's claim_to_headers APPENDS, so a client-sent value
      would otherwise survive beside the verified one (C5).

Usage: assert-ai-gateway.py [BUNDLE_DIR]    (default .bundle)
Exit:  0 clean, 1 violations (each printed), 2 bundle missing.
"""
import pathlib
import sys

import yaml

from yamlcompat import YAML_LOADER

AI_GATEWAY_CLASS = "envoy-ai-gateway"
IDENTITY_HEADERS = ("x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id")
COST_METADATA = {"namespace": "io.envoy.ai_gateway", "key": "llm_total_token"}


def ref(obj):
    meta = obj.get("metadata") or {}
    return f"{obj.get('kind')} {meta.get('namespace', '')}/{meta.get('name', '')}"


def spec_of(obj):
    return obj.get("spec") or {}


def load_objects(bundle_dir):
    objs = []
    for path in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        for doc in yaml.load_all(path.read_text(), Loader=YAML_LOADER):
            if isinstance(doc, dict) and doc.get("kind"):
                objs.append(doc)
    return objs


def check_rate_limit_rules(objs):
    errors = []
    for obj in objs:
        if obj.get("kind") != "BackendTrafficPolicy":
            continue
        rules = ((spec_of(obj).get("rateLimit") or {}).get("global") or {}).get("rules") or []
        for i, rule in enumerate(rules):
            where = f"{ref(obj)} rule {i}"
            if rule.get("shared") is not True:
                errors.append(f"{where}: shared must be true, or each route gets its own bucket")
            cost = rule.get("cost") or {}
            request = cost.get("request") or {}
            if request.get("from") != "Number" or request.get("number") != 0:
                errors.append(f"{where}: request cost must be Number 0, so the rule counts tokens, not calls")
            response = cost.get("response") or {}
            if response.get("from") != "Metadata" or response.get("metadata") != COST_METADATA:
                errors.append(f"{where}: response cost must be Metadata "
                              f"{COST_METADATA['namespace']}/{COST_METADATA['key']}")
            # OD-10 requires one week in shadow mode; PR 7 removes this check when enforcement starts.
            if rule.get("shadowMode") is not True:
                errors.append(f"{where}: shadowMode must be true for one week in shadow before enforcement")
    return errors


def check_identity_strips(objs):
    removed_by_gateway = {}
    for obj in objs:
        if obj.get("kind") != "ClientTrafficPolicy":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        early = (spec_of(obj).get("headers") or {}).get("earlyRequestHeaders") or {}
        removed = {h.lower() for h in early.get("remove") or []}
        for target in spec_of(obj).get("targetRefs") or []:
            # A sectionName scopes the policy to one listener; the invariant is per Gateway.
            if target.get("kind") == "Gateway" and not target.get("sectionName"):
                removed_by_gateway.setdefault((ns, target.get("name")), set()).update(removed)
    errors = []
    for obj in objs:
        if obj.get("kind") != "Gateway" or spec_of(obj).get("gatewayClassName") != AI_GATEWAY_CLASS:
            continue
        meta = obj.get("metadata") or {}
        have = removed_by_gateway.get((meta.get("namespace", ""), meta.get("name")), set())
        missing = [h for h in IDENTITY_HEADERS if h not in have]
        if missing:
            errors.append(f"{ref(obj)}: no whole-Gateway ClientTrafficPolicy removes "
                          f"{', '.join(missing)} before authentication")
    return errors


CHECKS = [check_rate_limit_rules, check_identity_strips]


def main(argv):
    bundle = pathlib.Path(argv[0] if argv else ".bundle")
    if not bundle.is_dir():
        print(f"error: bundle directory {bundle} not found; run render-bundle.py first", file=sys.stderr)
        return 2
    objs = load_objects(bundle)
    # The bundle holds a base and every overlay built on it, so one defect can
    # appear several times; report it once.
    errors = list(dict.fromkeys(e for check in CHECKS for e in check(objs)))
    for error in errors:
        print(f"FAIL {error}", file=sys.stderr)
    print(f"ai-gateway invariants: {len(CHECKS)} checks, {len(errors)} violations")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
