#!/usr/bin/env python3
"""Gate the rendered bundle on AI-gateway invariants that span objects.

`flux schema validate` checks each object alone. These rules relate objects,
and breaking any of them leaves every object valid and the gateway quietly
wrong:

  A1  Every global rate-limit rule on a BackendTrafficPolicy targeting a
      Gateway of class envoy-ai-gateway sets `shared: true`. The default gives
      every route its own bucket, multiplying each budget by the number of
      routes a principal can reach (programme contract C5). At least one such
      policy must exist -- zero is a layout regression, not compliance, and
      used to pass this check vacuously. A BackendTrafficPolicy that resolves
      to a different Gateway class, or that targets a route rather than a
      Gateway at all, is out of scope, so a future non-budget global rate
      limit elsewhere is not forced into this shape.
  A2  Every such rule charges tokens, not calls: request cost 0, response cost
      from io.envoy.ai_gateway/llm_total_token (SP4 design section 6).
  A3  Every Gateway of class envoy-ai-gateway is covered by a
      ClientTrafficPolicy that removes the identity headers before
      authentication -- and so is every listener-scoped ClientTrafficPolicy
      that targets it, since Envoy Gateway does not merge CTP levels: a
      listener-scoped policy REPLACES the Gateway-level one for that listener
      rather than adding to it, so relying on the Gateway-level strip alone
      would let a later, unrelated listener-scoped policy silently drop it. A
      Gateway is covered by a Gateway-scoped ClientTrafficPolicy, or by
      listener-scoped ones whose `sectionName`s cover every listener it
      declares (review M6). At least one Gateway of this class must exist in
      the bundle -- zero is a layout regression, not compliance, and used to
      pass this check vacuously.
  A4  A BackendTrafficPolicy that targets an HTTPRoute or AIGatewayRoute sets
      `mergeType`. Unset, it replaces rather than merges into the
      Gateway-level rules for that one route, silently exempting it from
      A1/A2.
  A5  On agent-system/agent-router, whose one-listener-per-data-class split
      is what keeps an `internal` token away from Z.ai (ADR-0042): every route
      (any kind) naming it sets `sectionName`, since without one it attaches
      to all three listeners; and every SecurityPolicy targeting such a route
      sets `mergeType`, since without one it replaces the listener's JWT check
      for that route. A target this bundle cannot resolve (an MCPRoute's
      generated HTTPRoute) or a label selector is assumed in scope. At least
      one route must attach -- zero is a layout regression. Other Gateways'
      routes may omit sectionName.
  A6  No MCPRoute on a Gateway of class envoy-ai-gateway lists `Authorization`
      (case-insensitive) in a backend's `forwardHeaders`, in
      `spec.securityPolicy.oauth.claimToHeaders[].header`, or as
      `spec.securityPolicy.apiKeyAuth.forwardClientIDHeader`. Envoy Gateway
      always forwards the validated JWT to the MCP proxy, and the MCPRoute
      API has no field to strip it; the proxy re-originates each backend
      call, so these are the three fields that feed forwarded headers -- any
      one of them can hand a run's token to an MCP server. At least one such
      MCPRoute must exist, for the same no-vacuous-pass reason.
  A7  Every agent-router listener that an AIGatewayRoute attaches to has an
      HTTPRoute on that same Gateway and sectionName which directly responds
      to an Exact `/v1/models` match via an HTTPRouteFilter's directResponse.
      Envoy AI Gateway enables its ext_proc per route, only on the
      AIGatewayRoute-generated routes -- and on agent-router's listeners
      ext_proc precedes jwt_authn in the filter chain, so without this guard
      ext_proc answers GET /v1/models itself before authentication ever runs
      (verified live: no token, a wrong audience and a forged token all
      returned 200). At least one AIGatewayRoute must attach to agent-router --
      zero is a layout regression, not compliance, and used to pass this check
      vacuously.

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


def ai_gateways(objs):
    """Gateways of class envoy-ai-gateway -- the checks below scope to just these."""
    return [obj for obj in objs if obj.get("kind") == "Gateway"
            and spec_of(obj).get("gatewayClassName") == AI_GATEWAY_CLASS]


def check_rate_limit_rules(objs):
    # Resolve every Gateway's class so a BackendTrafficPolicy that targets a
    # non-ai-gateway Gateway (a future, unrelated global rate limit) is left
    # alone rather than forced into token-budget shape. A target we cannot
    # resolve (not in this bundle slice) is assumed in scope.
    gateway_classes = {((g.get("metadata") or {}).get("namespace", ""), (g.get("metadata") or {}).get("name")):
                       spec_of(g).get("gatewayClassName") for g in objs if g.get("kind") == "Gateway"}

    def targets_ai_gateway(obj):
        ns = (obj.get("metadata") or {}).get("namespace", "")
        gateway_targets = [t for t in spec_of(obj).get("targetRefs") or [] if t.get("kind") == "Gateway"]
        # No Gateway targetRef at all -- a route-only policy (an ordinary rate
        # limit on some unrelated HTTPRoute, say) -- is out of scope for A1/A2.
        # It still owes A4's mergeType, checked unconditionally below.
        if not gateway_targets:
            return False
        return any(gateway_classes.get((ns, t.get("name")), AI_GATEWAY_CLASS) == AI_GATEWAY_CLASS
                   for t in gateway_targets)

    errors = []
    covered = False
    for obj in objs:
        if obj.get("kind") != "BackendTrafficPolicy":
            continue
        spec = spec_of(obj)
        # mergeType applies regardless of scope: an unset one on a route-level
        # policy silently drops the Gateway-level budget rules for that route,
        # whichever Gateway it belongs to.
        route_targets = [t for t in spec.get("targetRefs") or [] if t.get("kind") in ("HTTPRoute", "AIGatewayRoute")]
        if route_targets and not spec.get("mergeType"):
            errors.append(f"{ref(obj)}: targets a route without mergeType, so it replaces rather than "
                          "merges into the Gateway-level budget rules for that route")
        if not targets_ai_gateway(obj):
            continue
        rules = ((spec.get("rateLimit") or {}).get("global") or {}).get("rules") or []
        if rules:
            covered = True
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
    if not covered:
        errors.append(f"no BackendTrafficPolicy targets a Gateway of class {AI_GATEWAY_CLASS} with global "
                      "rate-limit rules (a bundle-layout change may have dropped it; this check cannot pass vacuously)")
    return errors


def check_identity_strips(objs):
    gateways = ai_gateways(objs)
    errors = []
    if not gateways:
        errors.append(f"no Gateway of class {AI_GATEWAY_CLASS} found in the bundle "
                      "(a bundle-layout change may have dropped it; this check cannot pass vacuously)")
    gateway_keys = {((g.get("metadata") or {}).get("namespace", ""), (g.get("metadata") or {}).get("name"))
                    for g in gateways}

    # Gateway-scoped policies (whole) cover every listener; listener-scoped ones
    # (sections) cover only the sectionNames they name -- Envoy Gateway does not
    # merge CTP levels, so a listener left out of every sections[key] entry is
    # unstripped even though the Gateway itself looks targeted.
    whole, sections = set(), {}
    for obj in objs:
        if obj.get("kind") != "ClientTrafficPolicy":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        early = (spec_of(obj).get("headers") or {}).get("earlyRequestHeaders") or {}
        removed = {h.lower() for h in early.get("remove") or []}
        for target in spec_of(obj).get("targetRefs") or []:
            if target.get("kind") != "Gateway":
                continue
            key = (ns, target.get("name"))
            if key not in gateway_keys:
                continue
            if target.get("sectionName"):
                sections.setdefault(key, set()).add(target["sectionName"])
            else:
                whole.add(key)
            # A sectionName scopes the policy to one listener. Envoy Gateway
            # does not merge CTP levels, so a listener-scoped policy REPLACES
            # the Gateway-level one for that listener and must independently
            # strip every header rather than relying on a baseline it has
            # just overridden.
            missing = [h for h in IDENTITY_HEADERS if h not in removed]
            if missing:
                listener = f" on listener {target['sectionName']}" if target.get("sectionName") else ""
                errors.append(f"{ref(obj)}: does not remove {', '.join(missing)} before authentication{listener}")

    for obj in gateways:
        meta = obj.get("metadata") or {}
        key = (meta.get("namespace", ""), meta.get("name"))
        if key in whole:
            continue
        if key not in sections:
            errors.append(f"{ref(obj)}: no ClientTrafficPolicy removes the identity headers before authentication")
            continue
        listeners = {listener.get("name") for listener in spec_of(obj).get("listeners") or []}
        uncovered = sorted(listeners - sections[key])
        if not listeners or uncovered:
            errors.append(f"{ref(obj)}: no Gateway-scoped ClientTrafficPolicy, and no listener-scoped one "
                          f"covers listener(s) {', '.join(uncovered) or '(none declared)'}")
    return errors


AGENT_ROUTER = ("agent-system", "agent-router")


def check_agent_router_routes(objs):
    errors = []
    attached, elsewhere = set(), set()
    for obj in objs:
        kind = obj.get("kind", "")
        if not kind.endswith("Route"):
            continue
        meta = obj.get("metadata") or {}
        ns, name = meta.get("namespace", ""), meta.get("name")
        parents = [p for p in spec_of(obj).get("parentRefs") or []
                   if (p.get("kind") or "Gateway") == "Gateway"
                   and ((p.get("namespace") or ns), p.get("name")) == AGENT_ROUTER]
        # An AIGatewayRoute generates the HTTPRoute a SecurityPolicy targets, under the same name.
        keys = {(ns, kind, name)} | ({(ns, "HTTPRoute", name)} if kind == "AIGatewayRoute" else set())
        (attached if parents else elsewhere).update(keys)
        if any(not p.get("sectionName") for p in parents):
            errors.append(f"{ref(obj)}: parentRef agent-router has no sectionName, so it attaches to every "
                          "listener (public, internal and sts)")
    if not attached:
        errors.append(f"no route attaches to Gateway {'/'.join(AGENT_ROUTER)} "
                      "(a bundle-layout change may have dropped it; this check cannot pass vacuously)")

    # targetRefs are namespace-local, so only agent-system's policies can reach its routes.
    for obj in objs:
        spec = spec_of(obj)
        ns = (obj.get("metadata") or {}).get("namespace", "")
        if obj.get("kind") != "SecurityPolicy" or spec.get("mergeType") or ns != AGENT_ROUTER[0]:
            continue
        refs = (spec.get("targetRefs") or []) + ([spec["targetRef"]] if spec.get("targetRef") else [])
        keys = [(ns, t.get("kind"), t.get("name")) for t in refs if (t.get("kind") or "").endswith("Route")]
        by_ref = any(key in attached or key not in elsewhere for key in keys)
        by_selector = any((s.get("kind") or "").endswith("Route") for s in spec.get("targetSelectors") or [])
        if by_ref or by_selector:
            errors.append(f"{ref(obj)}: targets an agent-router route without mergeType, so it replaces "
                          "the listener's JWT check for that route")
    return errors


def check_mcp_token_passthrough(objs):
    gateway_keys = {((g.get("metadata") or {}).get("namespace", ""), (g.get("metadata") or {}).get("name"))
                    for g in ai_gateways(objs)}
    errors = []
    covered = False
    for obj in objs:
        if obj.get("kind") != "MCPRoute":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        spec = spec_of(obj)
        if not any(p.get("kind", "Gateway") == "Gateway" and (p.get("namespace") or ns, p.get("name")) in gateway_keys
                   for p in spec.get("parentRefs") or []):
            continue
        covered = True
        for backend in spec.get("backendRefs") or []:
            if any((h.get("name") or "").lower() == "authorization" for h in backend.get("forwardHeaders") or []):
                errors.append(f"{ref(obj)}: backend {backend.get('name')} forwards Authorization, "
                              "handing the run's token to an MCP server")
        security = spec.get("securityPolicy") or {}
        claim_to_headers = (security.get("oauth") or {}).get("claimToHeaders") or []
        if any((c.get("header") or "").lower() == "authorization" for c in claim_to_headers):
            errors.append(f"{ref(obj)}: securityPolicy.oauth.claimToHeaders maps a claim onto Authorization, "
                          "handing the run's token to an MCP server")
        client_id_header = (security.get("apiKeyAuth") or {}).get("forwardClientIDHeader") or ""
        if client_id_header.lower() == "authorization":
            errors.append(f"{ref(obj)}: securityPolicy.apiKeyAuth.forwardClientIDHeader is Authorization, "
                          "handing the run's token to an MCP server")
    if not covered:
        errors.append(f"no MCPRoute attached to a Gateway of class {AI_GATEWAY_CLASS} found in the bundle "
                      "(a bundle-layout change may have dropped it; this check cannot pass vacuously)")
    return errors


def _agent_router_sections(obj):
    """sectionNames obj's parentRefs pin it to on Gateway agent-router (namespace-local)."""
    ns = (obj.get("metadata") or {}).get("namespace", "")
    sections = set()
    for p in spec_of(obj).get("parentRefs") or []:
        if (p.get("kind") or "Gateway") != "Gateway":
            continue
        if ((p.get("namespace") or ns), p.get("name")) != AGENT_ROUTER:
            continue
        if p.get("sectionName"):
            sections.add(p["sectionName"])
    return sections


def check_v1_models_guard(objs):
    # HTTPRouteFilters that actually direct-respond -- an ExtensionRef to one
    # missing directResponse (a rewrite filter, say) does not guard anything.
    direct_response_filters = {
        ((f.get("metadata") or {}).get("namespace", ""), (f.get("metadata") or {}).get("name"))
        for f in objs if f.get("kind") == "HTTPRouteFilter" and spec_of(f).get("directResponse") is not None
    }

    listeners = set()
    for obj in objs:
        if obj.get("kind") == "AIGatewayRoute":
            listeners |= _agent_router_sections(obj)

    guarded = set()
    for obj in objs:
        if obj.get("kind") != "HTTPRoute":
            continue
        ns = (obj.get("metadata") or {}).get("namespace", "")
        sections = _agent_router_sections(obj)
        if not sections:
            continue
        for rule in spec_of(obj).get("rules") or []:
            exact_models = any((m.get("path") or {}).get("type") == "Exact"
                               and (m.get("path") or {}).get("value") == "/v1/models"
                               for m in rule.get("matches") or [])
            if not exact_models:
                continue
            for filt in rule.get("filters") or []:
                if filt.get("type") != "ExtensionRef":
                    continue
                ext = filt.get("extensionRef") or {}
                if ext.get("kind") == "HTTPRouteFilter" and (ns, ext.get("name")) in direct_response_filters:
                    guarded |= sections

    errors = []
    if not listeners:
        errors.append(f"no AIGatewayRoute attaches to Gateway {'/'.join(AGENT_ROUTER)} "
                      "(a bundle-layout change may have dropped it; this check cannot pass vacuously)")
    for section in sorted(listeners - guarded):
        errors.append(f"Gateway {'/'.join(AGENT_ROUTER)} listener {section}: an AIGatewayRoute attaches here "
                      "but no HTTPRoute directly responds to an Exact /v1/models match, so its ext_proc "
                      "answers GET /v1/models itself before jwt_authn runs")
    return errors


CHECKS = [check_rate_limit_rules, check_identity_strips, check_agent_router_routes, check_mcp_token_passthrough,
          check_v1_models_guard]


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
