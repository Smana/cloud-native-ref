#!/usr/bin/env python3
"""Gate the rendered bundle on the agent router's agentgateway invariants (ADR-0042, ADR-0053).

Each check relates objects that `flux schema validate` sees one at a time, and
breaking any of them leaves every object valid and the boundary quietly open.
A Gateway of class agentgateway is judged against its entry in PROFILES, which
names its listeners, audiences, caller namespace and route namespace:

  AG1  Every Gateway of class agentgateway has a profile, declares exactly its
       listeners and ports, and admits routes from its route namespace only.
       No such Gateway at all is a layout regression, not compliance.
  AG2  Each listener has exactly one listener-scoped jwtAuthentication: mode
       Strict, audiences equal to its class set, requiredClaims holding exp and
       sub, an authorization Require on the caller namespace's sub prefix, and
       a `set` of x-ar-agent from jwt.sub.
  AG3  A Gateway-scoped PreRouting transformation removes the four identity
       headers before routing.
  AG4  preserveToken is true on the sts listener and nowhere else, and no MCP
       target credential or transformation writes Authorization.
  AG5  Every route on the Gateway sets sectionName and lives in the route
       namespace; a Z.ai backend is reachable from `public` only; no policy
       other than the listener ones carries jwtAuthentication. A Z.ai backend
       uses the custom provider: 1.6 keeps `openai` for the OpenAI API.
  AG6  Every MCP authorization is an Allow list whose expressions are each one
       complete alternative (role AND target AND tool names), for the route's
       own class: Allow expressions are OR-ed at runtime (PoC N7).
  AG7  Every listener with an LLM route answers an Exact /v1/models with a
       404 direct response (PoC N3).
  AG8  Every rateLimit.global fails open, charges Tokens, names no route or
       backend, and its domain resolves to a rate-limit ConfigMap whose
       matching descriptors are in shadow mode.
  AG9  The Gateway's AgentgatewayParameters keeps the constitution's pod shape
       (seccomp, liveness, memory limit), ClusterIP, 2 replicas, a PDB, a
       digest-pinned image, and shutdown {min: 10, max: 660} (PoC N1).
  AG11 A provider with a host override names its path (1.6 sends `/` when the
       base has none), and a Z.ai backend routes typed formats only: Detect
       and Passthrough join the path wrongly (#3853).

1.6 CRDs store no defaults, so every check reads explicit fields: an absent
field fails rather than being assumed. The bundle holds base and per-cluster
renders of the same objects, so the checks run once per cluster.

Usage: assert-agent-gateway.py [BUNDLE_DIR]    (default .bundle)
Exit:  0 clean, 1 violations (each printed), 2 bundle missing.
"""
import pathlib
import re
import sys
from typing import NamedTuple

import yaml

from yamlcompat import YAML_LOADER

CLASS = "agentgateway"
API_GROUP = "agentgateway.dev"
ROLES = ("implementer", "reviewer", "tester", "triager")
IDENTITY_HEADERS = ("x-ar-agent", "x-ar-human", "x-ai-gateway-client-id", "agent-session-id")
REQUIRED_CLAIMS = {"exp", "sub"}
SHUTDOWN = {"min": 10, "max": 660}
UNTYPED_ROUTES = {"Detect", "Passthrough"}
ROUTE_KINDS = ("HTTPRoute", "GRPCRoute")
CLUSTER = re.compile(r"-((?:aws|gcp)-\d+)-")


class Profile(NamedTuple):
    listeners: dict
    routes_ns: str
    aud_prefix: str
    sub_ns: str
    roles: tuple = ROLES


# Keyed by Gateway (namespace, name). Phase H removes the PoC with its entry.
PROFILES = {
    ("agent-gateway", "agent-router"): Profile(
        listeners={"public": 8080, "internal": 8081, "sts": 8082},
        routes_ns="agent-system", aud_prefix="agent-router", sub_ns="agents"),
    ("agw-poc", "agent-router-agw"): Profile(
        listeners={"public": 8080, "internal": 8081},
        routes_ns="agw-poc", aud_prefix="agw-poc", sub_ns="agw-poc-clients", roles=("implementer", "reviewer")),
}


def audiences(prof, listener):
    if listener == "sts":
        return {f"octo-sts/Smana/cloud-native-ref/{r}" for r in prof.roles}
    return {f"{prof.aud_prefix}.{r}.{listener}" for r in prof.roles}


def sub_prefix(prof):
    return f'jwt.sub.startsWith("system:serviceaccount:{prof.sub_ns}:")'


def alternative(prof):
    """The N7 grammar: one role, one target, its tool names. Reused by C.2's scope test."""
    name = r'"[a-z0-9_]+"'
    return re.compile(
        rf'^"{re.escape(prof.aud_prefix)}\.(?P<role>[a-z]+)\.(?P<cls>public|internal)" in jwt\.aud'
        r' && mcp\.tool\.target == "(?P<target>[a-z0-9-]+)"'
        rf' && mcp\.tool\.name (== {name}|in \[{name}(, {name})*\])$')


def meta(obj):
    return obj.get("metadata") or {}


def spec_of(obj):
    return obj.get("spec") or {}


def ref(obj):
    return f"{obj.get('kind')} {meta(obj).get('namespace', '')}/{meta(obj).get('name', '')}"


def key(obj):
    return meta(obj).get("namespace"), meta(obj).get("name")


def kind(objs, k):
    return [o for o in objs if o.get("kind") == k]


def policies(objs):
    return kind(objs, "AgentgatewayPolicy")


def gateways(objs):
    """(Gateway, Profile or None) for every Gateway of class agentgateway."""
    return [(g, PROFILES.get(key(g))) for g in kind(objs, "Gateway") if spec_of(g).get("gatewayClassName") == CLASS]


def profiled(objs):
    return [(g, p) for g, p in gateways(objs) if p]


def gateway_targets(policy, gw):
    """sectionName (or None) of each targetRef naming the Gateway from its own namespace."""
    if meta(policy).get("namespace") != meta(gw).get("namespace"):
        return []
    return [t.get("sectionName") for t in spec_of(policy).get("targetRefs") or []
            if t.get("kind") == "Gateway" and t.get("name") == meta(gw).get("name")]


def parents(route, gw):
    return [p for p in spec_of(route).get("parentRefs") or []
            if p.get("kind", "Gateway") == "Gateway" and p.get("name") == meta(gw).get("name")
            and p.get("namespace", meta(route).get("namespace")) == meta(gw).get("namespace")]


def routes_on(objs, gw):
    return [r for r in objs if r.get("kind") in ROUTE_KINDS and parents(r, gw)]


def listeners_of(route, gw):
    return {p.get("sectionName") for p in parents(route, gw)}


def backend_refs(route, rule_names=None):
    """(namespace, name) of every AgentgatewayBackend the route's (named) rules send to."""
    out = set()
    for rule in spec_of(route).get("rules") or []:
        if rule_names is not None and rule.get("name") not in rule_names:
            continue
        for b in rule.get("backendRefs") or []:
            if b.get("kind") == "AgentgatewayBackend":
                out.add((b.get("namespace", meta(route).get("namespace")), b.get("name")))
    return out


def providers(backend):
    """Every LLM provider block: ai.provider, or each one in ai.groups[].providers[]."""
    ai = spec_of(backend).get("ai") or {}
    found = [ai["provider"]] if ai.get("provider") else []
    return found + [p for g in ai.get("groups") or [] for p in g.get("providers") or []]


def is_zai(backend):
    hosts = [str(p.get("host", "")) for p in providers(backend)]
    return bool(providers(backend)) and (any(h == "z.ai" or h.endswith(".z.ai") for h in hosts)
                                         or "zai" in str(meta(backend).get("name", "")))


def check_gateway(objs):
    gws = gateways(objs)
    if not gws:
        return [f"AG1: no Gateway of class {CLASS} (zero is a layout regression, not compliance)"]
    out = []
    for g, prof in gws:
        if prof is None:
            out.append(f"AG1: {ref(g)} is a Gateway of class {CLASS} with no entry in PROFILES")
            continue
        got = {lst.get("name"): lst.get("port") for lst in spec_of(g).get("listeners") or []}
        if got != prof.listeners:
            out.append(f"AG1: {ref(g)} listeners are {got}, expected {prof.listeners}")
        for lst in spec_of(g).get("listeners") or []:
            ns = (lst.get("allowedRoutes") or {}).get("namespaces") or {}
            labels = (ns.get("selector") or {}).get("matchLabels") or {}
            same = ns.get("from") == "Same" and prof.routes_ns == meta(g).get("namespace")
            selected = ns.get("from") == "Selector" and labels == {"kubernetes.io/metadata.name": prof.routes_ns}
            if not (same or selected):
                out.append(f"AG1: {ref(g)} listener {lst.get('name')} must admit routes from {prof.routes_ns} only")
    return out


def check_listener_identity(objs):
    out = []
    listener_policies = set()
    for g, prof in profiled(objs):
        by_listener = {name: [] for name in prof.listeners}
        for p in policies(objs):
            if (spec_of(p).get("traffic") or {}).get("jwtAuthentication") is None:
                continue
            for s in gateway_targets(p, g):
                if s in by_listener:
                    by_listener[s].append(p)
                    listener_policies.add(id(p))
        for listener, found in by_listener.items():
            if len(found) != 1:
                out.append(f"AG2: {ref(g)} listener {listener} has {len(found)} jwtAuthentication policies, expected 1")
                continue
            p = found[0]
            traffic = spec_of(p).get("traffic") or {}
            jwt = traffic.get("jwtAuthentication") or {}
            if jwt.get("mode") != "Strict":
                out.append(f"AG2: {ref(p)} jwtAuthentication.mode must be Strict")
            provs = jwt.get("providers") or []
            auds = {a for prov in provs for a in prov.get("audiences") or []}
            if len(provs) != 1 or auds != audiences(prof, listener):
                out.append(f"AG2: {ref(p)} audiences are {sorted(auds)}, expected {sorted(audiences(prof, listener))}")
            for prov in provs:
                claims = set((prov.get("validation") or {}).get("requiredClaims") or [])
                if not REQUIRED_CLAIMS <= claims:
                    out.append(f"AG2: {ref(p)} requiredClaims {sorted(claims)} must hold exp and sub: "
                               "a sub-less token would share one unlimited rate-limit bucket (#3523)")
            authz = traffic.get("authorization") or {}
            exprs = (authz.get("policy") or {}).get("matchExpressions") or []
            if authz.get("action") != "Require" or exprs != [sub_prefix(prof)]:
                out.append(f"AG2: {ref(p)} must Require exactly {sub_prefix(prof)}")
            sets = ((traffic.get("transformation") or {}).get("request") or {}).get("set") or []
            if {"name": "x-ar-agent", "value": "jwt.sub"} not in sets:
                out.append(f"AG2: {ref(p)} must set x-ar-agent from jwt.sub")
            preserve = jwt.get("preserveToken") is True
            if preserve != (listener == "sts"):
                out.append(f"AG4: {ref(p)} preserveToken is {preserve}; only the sts listener forwards the bearer")
    for p in policies(objs):
        if (spec_of(p).get("traffic") or {}).get("jwtAuthentication") is not None and id(p) not in listener_policies:
            out.append(f"AG5: {ref(p)} carries jwtAuthentication but targets no profiled listener")
    return out


def check_strip(objs):
    out = []
    for g, _ in profiled(objs):
        for p in policies(objs):
            if None not in gateway_targets(p, g):
                continue
            traffic = spec_of(p).get("traffic") or {}
            req = (traffic.get("transformation") or {}).get("request") or {}
            removed = {h.lower() for h in req.get("remove") or []}
            if traffic.get("phase") == "PreRouting" and set(IDENTITY_HEADERS) <= removed:
                break
        else:
            out.append(f"AG3: no Gateway-scoped PreRouting policy on {ref(g)} removes {', '.join(IDENTITY_HEADERS)}")
    return out


def check_token_isolation(objs):
    out = []
    for p in policies(objs):
        traffic = spec_of(p).get("traffic") or {}
        if (traffic.get("jwtAuthentication") or {}).get("preserveToken") is True and not any(
                "sts" in gateway_targets(p, g) for g, _ in profiled(objs)):
            out.append(f"AG4: {ref(p)} sets preserveToken outside an sts listener")
        for section in (traffic, spec_of(p).get("backend") or {}):
            req = (section.get("transformation") or {}).get("request") or {}
            for h in (req.get("set") or []) + (req.get("add") or []):
                if str(h.get("name", "")).lower() == "authorization":
                    out.append(f"AG4: {ref(p)} writes Authorization in a transformation")
    for b in kind(objs, "AgentgatewayBackend"):
        for t in (spec_of(b).get("mcp") or {}).get("targets") or []:
            auth = ((t.get("static") or {}).get("policies") or {}).get("auth")
            if not auth:
                continue
            creds = auth.get("credentials") or []
            headers = [((c.get("location") or {}).get("header") or {}).get("name", "") for c in creds]
            if set(auth) - {"credentials"} or not creds or any(not h or h.lower() == "authorization" for h in headers):
                out.append(f"AG4: {ref(b)} target {t.get('name')} must inject its key in a named header "
                           "other than Authorization")
    return out


def check_routes(objs):
    out = []
    zai = {key(b) for b in kind(objs, "AgentgatewayBackend") if is_zai(b)}
    for g, prof in profiled(objs):
        for r in routes_on(objs, g):
            if meta(r).get("namespace") != prof.routes_ns:
                out.append(f"AG5: {ref(r)} attaches to {ref(g)} from outside {prof.routes_ns}")
            if any(not p.get("sectionName") for p in parents(r, g)):
                out.append(f"AG5: {ref(r)} attaches to {ref(g)} without sectionName (it would bind every listener)")
            if backend_refs(r) & zai and listeners_of(r, g) != {"public"}:
                out.append(f"AG5: {ref(r)} reaches Z.ai from {sorted(listeners_of(r, g))}; Z.ai is public-only")
    return out


def check_zai_provider(objs):
    out = []
    for b in kind(objs, "AgentgatewayBackend"):
        if is_zai(b) and any("custom" not in p for p in providers(b)):
            out.append(f"AG5: {ref(b)} serves Z.ai without provider.custom (1.6: openai is for the OpenAI API only)")
    return out


def check_mcp_authz(objs):
    out = []
    for g, prof in profiled(objs):
        grammar = alternative(prof)
        for p in policies(objs):
            authz = ((spec_of(p).get("backend") or {}).get("mcp") or {}).get("authorization")
            names = {t.get("name") for t in spec_of(p).get("targetRefs") or [] if t.get("kind") in ROUTE_KINDS}
            routes = [r for r in routes_on(objs, g) if meta(r).get("name") in names
                      and meta(r).get("namespace") == meta(p).get("namespace")]
            if authz is None or not routes:
                continue
            classes = {s for r in routes for s in listeners_of(r, g)}
            if authz.get("action") != "Allow":
                out.append(f"AG6: {ref(p)} MCP authorization must be an Allow list (deny by default)")
            for e in (authz.get("policy") or {}).get("matchExpressions") or []:
                m = grammar.match(e.strip())
                if "||" in e or not m:
                    out.append(f"AG6: {ref(p)} expression is not one complete alternative: {e}")
                elif m.group("cls") not in classes:
                    out.append(f"AG6: {ref(p)} grants a {m.group('cls')} audience on {sorted(classes)} routes: {e}")
    return out


def exact_models_rules(route):
    return {rule.get("name") for rule in spec_of(route).get("rules") or []
            if any(m.get("path") == {"type": "Exact", "value": "/v1/models"} for m in rule.get("matches") or [])}


def check_models_list(objs):
    out = []
    llm = {key(b) for b in kind(objs, "AgentgatewayBackend") if providers(b)}
    for g, _ in profiled(objs):
        routes = routes_on(objs, g)
        llm_listeners = {s for r in routes if backend_refs(r) & llm for s in listeners_of(r, g)}
        answered = set()
        for p in policies(objs):
            if ((spec_of(p).get("traffic") or {}).get("directResponse") or {}).get("status") != 404:
                continue
            for t in spec_of(p).get("targetRefs") or []:
                for r in routes:
                    if t.get("kind") not in ROUTE_KINDS or t.get("name") != meta(r).get("name") \
                            or meta(p).get("namespace") != meta(r).get("namespace"):
                        continue
                    rules = exact_models_rules(r)
                    if rules and (t.get("sectionName") is None or t.get("sectionName") in rules):
                        answered |= listeners_of(r, g)
        for listener in sorted(llm_listeners - answered):
            out.append(f"AG7: {ref(g)} listener {listener} serves an LLM route but no Exact /v1/models "
                       "404 direct response")
    return out


def ratelimit_configs(objs):
    configs = {}
    for cm in kind(objs, "ConfigMap"):
        raw = (cm.get("data") or {}).get("config.yaml")
        if not raw:
            continue
        try:
            cfg = yaml.safe_load(raw)
        except yaml.YAMLError:
            continue
        if isinstance(cfg, dict) and cfg.get("domain") and isinstance(cfg.get("descriptors"), list):
            configs[cfg["domain"]] = (cm, cfg)
    return configs


def check_budgets(objs):
    out = []
    configs = ratelimit_configs(objs)
    for p in policies(objs):
        glob = ((spec_of(p).get("traffic") or {}).get("rateLimit") or {}).get("global")
        if glob is None:
            continue
        if glob.get("failureMode") != "FailOpen":
            out.append(f"AG8: {ref(p)} must set failureMode FailOpen (a store outage must not stop agents)")
        domain = glob.get("domain")
        if domain not in configs:
            out.append(f"AG8: {ref(p)} domain {domain!r} has no rate-limit ConfigMap in the bundle")
            continue
        cm, cfg = configs[domain]
        rules = {d.get("key"): d for d in cfg["descriptors"]}
        for d in glob.get("descriptors") or []:
            if d.get("unit") != "Tokens":
                out.append(f"AG8: {ref(p)} descriptor must charge unit Tokens")
            for entry in d.get("entries") or []:
                if re.search(r"route|backend|request\.path", f"{entry.get('name', '')} {entry.get('expression', '')}"):
                    out.append(f"AG8: {ref(p)} descriptor entry {entry.get('name')} keys on a route; "
                               "buckets must be shared")
                rule = rules.get(entry.get("name"))
                if rule is None:
                    out.append(f"AG8: {ref(p)} entry {entry.get('name')} has no descriptor in {ref(cm)}")
                elif rule.get("shadow_mode") is not True:
                    out.append(f"AG8: {ref(cm)} descriptor {entry.get('name')} must set shadow_mode: true "
                               "until enforcement")
    return out


def check_parameters(objs):
    out = []
    for g, _ in profiled(objs):
        pref = (spec_of(g).get("infrastructure") or {}).get("parametersRef") or {}
        params = next((p for p in kind(objs, "AgentgatewayParameters")
                       if key(p) == (meta(g).get("namespace"), pref.get("name"))), None)
        if params is None or pref.get("kind") != "AgentgatewayParameters":
            out.append(f"AG9: {ref(g)} has no AgentgatewayParameters in {meta(g).get('namespace')}")
            continue
        s = spec_of(params)
        dep = (s.get("deployment") or {}).get("spec") or {}
        pod = (dep.get("template") or {}).get("spec") or {}
        container = next((c for c in pod.get("containers") or [] if c.get("name") == "agentgateway"), {})
        shutdown = {k: v for k, v in (s.get("shutdown") or {}).items() if k in SHUTDOWN}
        checks = [
            ((dep.get("replicas") or 0) >= 2, "2 replicas"),
            (((pod.get("securityContext") or {}).get("seccompProfile") or {}).get("type") == "RuntimeDefault",
             "pod seccompProfile RuntimeDefault"),
            (((container.get("securityContext") or {}).get("seccompProfile") or {}).get("type") == "RuntimeDefault",
             "container seccompProfile RuntimeDefault"),
            (bool(container.get("livenessProbe")), "a liveness probe"),
            (bool(((s.get("resources") or {}).get("limits") or {}).get("memory")), "a memory limit"),
            ((((s.get("service") or {}).get("spec") or {}).get("type")) == "ClusterIP", "service type ClusterIP"),
            (bool((s.get("podDisruptionBudget") or {}).get("spec")), "a PodDisruptionBudget"),
            (bool((s.get("image") or {}).get("digest")), "a digest-pinned image"),
            (shutdown == SHUTDOWN, f"shutdown {SHUTDOWN} (got {s.get('shutdown')})"),
        ]
        out += [f"AG9: {ref(params)} lacks {what}" for ok, what in checks if not ok]
    return out


def check_provider_paths(objs):
    out = []
    for b in kind(objs, "AgentgatewayBackend"):
        for prov in providers(b):
            if not prov.get("host"):
                continue
            formats = (prov.get("custom") or {}).get("formats") or []
            pathed = prov.get("path") or prov.get("pathPrefix") or (formats and all(f.get("path") for f in formats))
            if not pathed:
                out.append(f"AG11: {ref(b)} overrides host {prov['host']} without a path; 1.6 sends `/`")
        if not is_zai(b):
            continue
        routes = ((spec_of(b).get("policies") or {}).get("ai") or {}).get("routes") or {}
        if not routes:
            out.append(f"AG11: {ref(b)} serves Z.ai without typed policies.ai.routes (#3853)")
        for path, typ in routes.items():
            if typ in UNTYPED_ROUTES:
                out.append(f"AG11: {ref(b)} routes {path} as {typ}; Z.ai takes typed routes only (#3853)")
    return out


CHECKS = (check_gateway, check_listener_identity, check_strip, check_token_isolation, check_routes,
          check_zai_provider, check_mcp_authz, check_models_list, check_budgets, check_parameters,
          check_provider_paths)


def run(objs):
    """Violations for one cluster's objects, each starting with its check id."""
    return list(dict.fromkeys(v for check in CHECKS for v in check(objs)))


def is_agentgateway(obj):
    return str(obj.get("apiVersion", "")).startswith(API_GROUP + "/") or (
        obj.get("kind") == "Gateway" and spec_of(obj).get("gatewayClassName") == CLASS)


def load_clusters(bundle_dir):
    """Objects per cluster, from the renders whose file name carries one (base renders repeat them)."""
    clusters = {}
    for path in sorted(pathlib.Path(bundle_dir).glob("*.yaml")):
        m = CLUSTER.search(path.name)
        if not m:
            continue
        for doc in yaml.load_all(path.read_text(), Loader=YAML_LOADER):
            if isinstance(doc, dict) and doc.get("kind"):
                clusters.setdefault(m.group(1), []).append(doc)
    return clusters


def main(argv):
    bundle = pathlib.Path(argv[1] if len(argv) > 1 else ".bundle")
    if not bundle.is_dir():
        print(f"error: bundle directory {bundle} not found; run render-bundle.py first", file=sys.stderr)
        return 2
    in_scope = {c: objs for c, objs in load_clusters(bundle).items() if any(map(is_agentgateway, objs))}
    if in_scope:
        violations = [f"{v.split(':', 1)[0]}: [{c}]{v.split(':', 1)[1]}"
                      for c, objs in sorted(in_scope.items()) for v in run(objs)]
    else:
        violations = [f"AG1: no agentgateway object in any cluster's render (a vacuous pass is N10)"]
    for v in violations:
        print(f"FAIL {v}", file=sys.stderr)
    print(f"assert-agent-gateway: {len(CHECKS)} checks, {len(violations)} violations "
          f"(clusters: {', '.join(sorted(in_scope)) or 'none'})")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
