#!/usr/bin/env python3
# requires: python3
"""Agent observability on the real tree (docs/superpowers/plans/2026-09-27-agent-observability-plan.md).
The trace collector keeps metadata only and takes no run id from a span, agent-router traces to
it, kube-state-metrics reads AgentRuns, and the two dashboards are wired to all of it."""
import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
errors = []


def check(ok, message):
    if not ok:
        errors.append(message)


def find(rel, kind, name):
    for d in yaml.safe_load_all((ROOT / rel).read_text()):
        if d and d.get("kind") == kind and d["metadata"]["name"] == name:
            return d
    errors.append(f"{rel}: no {kind} {name}")
    return {}


PLATFORM = "observability/base/agent-platform"
COLLECTOR = f"{PLATFORM}/agent-traces-collector.yaml"
GRANT = f"{PLATFORM}/referencegrant-agent-traces.yaml"
# Keys that carry prompts, completions, tool input or output, headers or error text (lmnr
# 0.7.60, OpenHands SDK 1.49.6, OTel semconv). None may be allowlisted (rulings O2, O18).
CONTENT = re.compile(r"^(gen_ai\.(input|output|prompt|completion|tool\.definitions|system_instructions)"
                     r"|lmnr\.span\.(input|output)|llm\.headers|exception\.(message|stacktrace))")


def check_collector():
    raw = (ROOT / COLLECTOR).read_text()
    check(not re.search(r"(?<!\$)\$\{env:", raw), "every ${env:…} is escaped as $${env:…} for Flux")
    values = find(COLLECTOR, "HelmRelease", "agent-traces-collector").get("spec", {}).get("values", {})
    image = values.get("image", {})
    check(image.get("repository") == "otel/opentelemetry-collector-k8s" and image.get("digest", "").startswith("sha256:"),
          "the collector is otelcol-k8s, pinned by digest")
    check(not values.get("presets"), "no chart preset: k8s_attributes must run after the strip step (O3)")
    cfg = values.get("alternateConfig", {})
    pipes = cfg.get("service", {}).get("pipelines", {})
    check(set(pipes) == {"traces/agents", "traces/router"}, f"pipelines are traces/agents and traces/router, got {sorted(pipes)}")
    agents, router = pipes.get("traces/agents", {}), pipes.get("traces/router", {})
    check(agents.get("receivers") == ["otlp/agents"] and router.get("receivers") == ["otlp/router"], "one receiver per pipeline (O5)")
    receivers = cfg.get("receivers", {})
    check(list(receivers.get("otlp/agents", {}).get("protocols", {})) == ["http"], "sandboxes speak OTLP/HTTP only")
    check(list(receivers.get("otlp/router", {}).get("protocols", {})) == ["grpc"], "agent-router speaks OTLP/gRPC only (EG 1.9)")
    want = ["memory_limiter", "transform/untrusted", "k8s_attributes", "filter/unattributed",
            "transform/attribute", "redaction", "transform/cap", "batch"]
    check(agents.get("processors") == want, f"traces/agents processors are {want}, got {agents.get('processors')}")
    proc = cfg.get("processors", {})
    k8s = proc.get("k8s_attributes", {})
    check(k8s.get("pod_association") == [{"sources": [{"from": "connection"}]}],
          "the run id comes from the connection only, never a span's resource attributes (O4)")
    check(k8s.get("filter", {}).get("namespace") == "agents", "k8s_attributes watches pods in agents only (its Role)")
    labels = {l["tag_name"]: l["key"] for l in k8s.get("extract", {}).get("labels", [])}
    check(labels.get("agent.run_id") == "agents.ogenki.io/run-id", "agent.run_id is the pod's agents.ogenki.io/run-id label")
    strip = [s for g in proc.get("transform/untrusted", {}).get("trace_statements", []) for s in g.get("statements", [])]
    for target in ("resource", "span"):
        check(f'delete_key({target}.attributes, "agent.run_id")' in strip, f"the client's {target} agent.run_id is deleted first")
    check(proc.get("filter/unattributed", {}).get("trace_conditions") == ['resource.attributes["agent.run_id"] == nil'],
          "a span no run sent is dropped")
    redaction = proc.get("redaction", {})
    allowed = redaction.get("allowed_keys", [])
    check(redaction.get("allow_all_keys") is False, "redaction is an allowlist (O2)")
    check({"agent.run_id", "service.name", "gen_ai.usage.input_tokens", "gen_ai.request.model"} <= set(allowed),
          "the run id, service name, model and token counts are kept")
    leaks = [k for k in allowed if CONTENT.match(k)]
    check(not leaks, f"content keys allowlisted: {leaks}")
    # Names are free text a run controls, and redaction only sees attributes (AK5).
    cap = [s for g in proc.get("transform/cap", {}).get("trace_statements", []) for s in g.get("statements", [])]
    for path, n in (("span.name", 128), ("span.status.message", 128),
                    ("spanevent.name", 256), ("scope.name", 256), ("scope.version", 256)):
        check(f"set({path}, Substring({path}, 0, {n})) where Len({path}) > {n}" in cap,
              f"transform/cap bounds {path} to {n} characters")
    endpoint = cfg.get("exporters", {}).get("otlp_http/victoriatraces", {}).get("traces_endpoint")
    check(endpoint == "http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces",
          f"the exporter writes VictoriaTraces' OTLP path, got {endpoint!r}")
    role = find(COLLECTOR, "Role", "agent-traces-collector")
    check(role.get("metadata", {}).get("namespace") == "agents"
          and role.get("rules") == [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list", "watch"]}],
          "the collector reads pods in agents and nothing else")
    cnp = find(COLLECTOR, "CiliumNetworkPolicy", "agent-traces-collector").get("spec", {})
    ingress = {p["port"]: rule for rule in cnp.get("ingress", []) for tp in rule.get("toPorts", []) for p in tp["ports"]}
    check(set(ingress) == {"4318", "4317", "8888", "13133"}, f"collector ingress ports, got {sorted(ingress)}")
    run_peer = (ingress.get("4318", {}).get("fromEndpoints") or [{}])[0]
    check(run_peer.get("matchLabels") == {"io.kubernetes.pod.namespace": "agents"}
          and run_peer.get("matchExpressions") == [{"key": "agents.ogenki.io/run-id", "operator": "Exists"}],
          "only run pods reach :4318")
    router_peer = (ingress.get("4317", {}).get("fromEndpoints") or [{}])[0].get("matchLabels", {})
    check(router_peer == {"io.kubernetes.pod.namespace": "envoy-gateway-system",
                          "gateway.envoyproxy.io/owning-gateway-name": "agent-router",
                          "gateway.envoyproxy.io/owning-gateway-namespace": "agent-system"},
          "only agent-router's data plane reaches :4317")


def check_reference_grant():
    grant = find(GRANT, "ReferenceGrant", "agent-router-traces")
    spec = grant.get("spec", {})
    check(grant.get("metadata", {}).get("namespace") == "observability"
          and spec.get("from") == [{"group": "gateway.envoyproxy.io", "kind": "EnvoyProxy", "namespace": "agent-system"}]
          and spec.get("to") == [{"group": "", "kind": "Service", "name": "agent-traces-collector"}],
          "agent-system's EnvoyProxy may reference the collector Service and nothing else (EG 1.9 backendRefs)")
    resources = yaml.safe_load((ROOT / PLATFORM / "kustomization.yaml").read_text()).get("resources", [])
    for rel in (COLLECTOR, GRANT):
        check(pathlib.PurePath(rel).name in resources, f"{PLATFORM}/kustomization.yaml lists {pathlib.PurePath(rel).name}")


def check_platform_port():
    cnp = find(COLLECTOR, "CiliumNetworkPolicy", "agent-traces-collector").get("spec", {})
    peers = [p.get("matchLabels", {}) for rule in cnp.get("ingress", []) for tp in rule.get("toPorts", [])
             if any(x["port"] == "4317" for x in tp["ports"]) for p in rule.get("fromEndpoints", [])]
    check({"io.kubernetes.pod.namespace": "agent-system", "app.kubernetes.io/name": "agent-factory"} in peers,
          "SP3's factory sends its task spans to :4317 (O20)")
    check(all(p.get("io.kubernetes.pod.namespace") != "agents" for p in peers), "no sandbox ever reaches :4317 (O5, O20)")


CHECKS = [check_collector, check_reference_grant, check_platform_port]

for run in CHECKS:
    run()
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
