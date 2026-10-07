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
                     r"|gen_ai\.tool\.call\.(arguments|result)|http\.(request|response)\.header\.|url\.(full|query)|http\.url"
                     r"|lmnr\.span\.(input|output)|llm\.headers|exception\.(message|stacktrace))")
EXPORTERS = ["otlp_http/victoriatraces"]
# Links and tracestate carry run-controlled text that no attribute processor sees, and names
# and versions are free text too, so they are capped rather than trusted. Substring is byte-based
# unless told otherwise.
CAPS = ["truncate_all(resource.attributes, 256)",
        "truncate_all(span.attributes, 256)",
        "truncate_all(spanevent.attributes, 256)",
        "set(span.links, nil)",
        'set(span.trace_state, "")'] + [
    f"set({path}, Substring({path}, 0, {n}, true)) where Len({path}) > {n}"
    for path, n in (("span.name", 128), ("span.status.message", 128),
                    ("spanevent.name", 256), ("scope.name", 256), ("scope.version", 256))]


def tcp(port):
    return [{"ports": [{"port": port, "protocol": "TCP"}]}]


# Whole rules, so an extra peer, entity or port-less rule fails too.
CNP_SELECTOR = {"matchLabels": {"app.kubernetes.io/name": "agent-traces-collector",
                                "app.kubernetes.io/instance": "agent-traces"}}
CNP_INGRESS = [
    # Run pods only (O4).
    {"fromEndpoints": [{"matchLabels": {"io.kubernetes.pod.namespace": "agents"},
                        "matchExpressions": [{"key": "agents.ogenki.io/run-id", "operator": "Exists"}]}],
     "toPorts": tcp("4318")},
    # agent-router's data plane, then SP3's factory (O20). No sandbox reaches :4317 (O5).
    {"fromEndpoints": [{"matchLabels": {"io.kubernetes.pod.namespace": "envoy-gateway-system",
                                        "gateway.envoyproxy.io/owning-gateway-name": "agent-router",
                                        "gateway.envoyproxy.io/owning-gateway-namespace": "agent-system"}},
                       {"matchLabels": {"io.kubernetes.pod.namespace": "agent-system",
                                        "app.kubernetes.io/name": "agent-factory"}}],
     "toPorts": tcp("4317")},
    {"fromEndpoints": [{"matchLabels": {"io.kubernetes.pod.namespace": "observability",
                                        "app.kubernetes.io/name": "vmagent"}}],
     "toPorts": tcp("8888")},
    {"fromEntities": ["host"], "toPorts": tcp("13133")},
]
CNP_EGRESS = [
    {"toEndpoints": [{"matchLabels": {"io.kubernetes.pod.namespace": "kube-system", "k8s-app": "kube-dns"}}],
     "toPorts": [{"ports": [{"port": "53", "protocol": "UDP"}, {"port": "53", "protocol": "TCP"}],
                  "rules": {"dns": [{"matchPattern": "*"}]}}]},
    {"toEntities": ["kube-apiserver"], "toPorts": tcp("443")},
    {"toEndpoints": [{"matchLabels": {"io.kubernetes.pod.namespace": "observability",
                                      "app.kubernetes.io/name": "vt-single"}}],
     "toPorts": tcp("10428")},
]


def check_collector():
    raw = (ROOT / COLLECTOR).read_text()
    check(not re.search(r"(?<!\$)\$\{env:", raw), "every ${env:…} is escaped as $${env:…} for Flux")
    hr = find(COLLECTOR, "HelmRelease", "agent-traces-collector").get("spec", {})
    values = hr.get("values", {})
    # The chart labels pods instance=<releaseName>, and CI renders with the object name instead
    # (render-bundle.py), so only this ties the selectors to the real pods.
    check(hr.get("releaseName") == CNP_SELECTOR["matchLabels"]["app.kubernetes.io/instance"],
          f"releaseName {hr.get('releaseName')!r} is the instance label the CNP selects")
    check(find(COLLECTOR, "VMServiceScrape", "agent-traces-collector").get("spec", {}).get("selector") == CNP_SELECTOR,
          "the VMServiceScrape selects the same pods as the CNP")
    # Without it `set(span.links, nil)` is a silent no-op on 0.160, and link attributes reach storage.
    check("--feature-gates=ottl.set.allowNil" in values.get("command", {}).get("extraArgs", []),
          "the collector runs with ottl.set.allowNil, so set(span.links, nil) clears links")
    image = values.get("image", {})
    check(image.get("repository") == "otel/opentelemetry-collector-k8s"
          and re.fullmatch(r"sha256:[0-9a-f]{64}", image.get("digest", "")),
          "the collector is otelcol-k8s, pinned by digest")
    check(not values.get("presets"), "no chart preset: k8s_attributes must run after the strip step (O3)")
    check(values.get("clusterRole", {}).get("create") is False,
          "the chart's ClusterRole is off: the collector's only API read is the Role below")
    res = values.get("resources", {})
    check(all(res.get(k, {}).get(r) for k in ("requests", "limits") for r in ("cpu", "memory")),
          "cpu and memory requests and limits are set")
    sc, psc = values.get("securityContext", {}), values.get("podSecurityContext", {})
    check(sc.get("allowPrivilegeEscalation") is False and sc.get("readOnlyRootFilesystem") is True
          and sc.get("runAsNonRoot") is True and sc.get("capabilities") == {"drop": ["ALL"]}
          and sc.get("seccompProfile") == {"type": "RuntimeDefault"}
          and psc.get("runAsNonRoot") is True and psc.get("seccompProfile") == {"type": "RuntimeDefault"},
          "the pod and container securityContexts are restricted")
    cfg = values.get("alternateConfig", {})
    pipes = cfg.get("service", {}).get("pipelines", {})
    check(set(pipes) == {"traces/agents", "traces/router"}, f"pipelines are traces/agents and traces/router, got {sorted(pipes)}")
    agents, router = pipes.get("traces/agents", {}), pipes.get("traces/router", {})
    check(agents.get("receivers") == ["otlp/agents"] and router.get("receivers") == ["otlp/router"], "one receiver per pipeline (O5)")
    check(agents.get("exporters") == EXPORTERS and router.get("exporters") == EXPORTERS,
          f"both pipelines export to VictoriaTraces only, got {agents.get('exporters')} and {router.get('exporters')}")
    receivers = cfg.get("receivers", {})
    check(list(receivers.get("otlp/agents", {}).get("protocols", {})) == ["http"], "sandboxes speak OTLP/HTTP only")
    check(list(receivers.get("otlp/router", {}).get("protocols", {})) == ["grpc"], "agent-router speaks OTLP/gRPC only (EG 1.9)")
    want = ["memory_limiter", "transform/untrusted", "k8s_attributes", "filter/unattributed",
            "transform/attribute", "redaction", "transform/cap", "batch"]
    check(agents.get("processors") == want, f"traces/agents processors are {want}, got {agents.get('processors')}")
    # Platform spans carry run-controlled strings too (path, user agent, tracestate): capped, not allowlisted.
    want = ["memory_limiter", "transform/cap", "batch"]
    check(router.get("processors") == want, f"traces/router processors are {want}, got {router.get('processors')}")
    proc = cfg.get("processors", {})
    k8s = proc.get("k8s_attributes", {})
    check(k8s.get("pod_association") == [{"sources": [{"from": "connection"}]}],
          "the run id comes from the connection only, never a span's resource attributes (O4)")
    check(k8s.get("passthrough") is False, "k8s_attributes resolves the pod itself, not just tags its IP")
    check(k8s.get("filter", {}).get("namespace") == "agents", "k8s_attributes watches pods in agents only (its Role)")
    labels = {l["tag_name"]: l["key"] for l in k8s.get("extract", {}).get("labels", [])}
    check(labels.get("agent.run_id") == "agents.ogenki.io/run-id", "agent.run_id is the pod's agents.ogenki.io/run-id label")
    # Every key k8s_attributes sets is deleted from the client's copy first, or the client's would win.
    strip = [s for g in proc.get("transform/untrusted", {}).get("trace_statements", []) for s in g.get("statements", [])]
    check(strip == [f'delete_key(resource.attributes, "{k}")'
                    for k in ("agent.run_id", "agent.role", "k8s.pod.name", "k8s.namespace.name")]
          + ['delete_key(span.attributes, "agent.run_id")'],
          "the client's agent.run_id, agent.role and pod identity are deleted before k8s_attributes (O4)")
    stamp = [s for g in proc.get("transform/attribute", {}).get("trace_statements", []) for s in g.get("statements", [])]
    check(stamp == ['set(resource.attributes["service.name"], "agent-harness")',
                    'set(span.attributes["agent.run_id"], resource.attributes["agent.run_id"])'],
          "service.name is agent-harness and every span carries the run id")
    check(proc.get("filter/unattributed", {}).get("trace_conditions") == ['resource.attributes["agent.run_id"] == nil'],
          "a span no run sent is dropped")
    redaction = proc.get("redaction", {})
    allowed = redaction.get("allowed_keys", [])
    check(redaction.get("allow_all_keys") is False, "redaction is an allowlist (O2)")
    check(redaction.get("summary") in ("silent", "info"), "redaction's summary never writes key names (debug does)")
    check({"agent.run_id", "service.name", "gen_ai.usage.input_tokens", "gen_ai.request.model"} <= set(allowed),
          "the run id, service name, model and token counts are kept")
    leaks = [k for k in allowed if CONTENT.match(k)]
    check(not leaks, f"content keys allowlisted: {leaks}")
    cap = [s for g in proc.get("transform/cap", {}).get("trace_statements", []) for s in g.get("statements", [])]
    for statement in CAPS:
        check(statement in cap, f"transform/cap has `{statement}`")
    endpoint = cfg.get("exporters", {}).get("otlp_http/victoriatraces", {}).get("traces_endpoint")
    check(endpoint == "http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces",
          f"the exporter writes VictoriaTraces' OTLP path, got {endpoint!r}")
    role = find(COLLECTOR, "Role", "agent-traces-collector")
    check(role.get("metadata", {}).get("namespace") == "agents"
          and role.get("rules") == [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list", "watch"]}],
          "the collector reads pods in agents and nothing else")
    binding = find(COLLECTOR, "RoleBinding", "agent-traces-collector")
    check(binding.get("metadata", {}).get("namespace") == "agents"
          and binding.get("roleRef") == {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role", "name": "agent-traces-collector"}
          and binding.get("subjects") == [{"kind": "ServiceAccount", "name": "agent-traces-collector", "namespace": "observability"}],
          "the Role is bound to the collector's ServiceAccount only")
    cnp = find(COLLECTOR, "CiliumNetworkPolicy", "agent-traces-collector").get("spec", {})
    check(cnp.get("endpointSelector") == CNP_SELECTOR, f"the CNP selects the collector pods, got {cnp.get('endpointSelector')}")
    check(cnp.get("ingress") == CNP_INGRESS, "collector ingress is exactly run pods on :4318, agent-router and the "
          "factory on :4317, vmagent on :8888 and kubelet on :13133")
    check(cnp.get("egress") == CNP_EGRESS, "collector egress is exactly kube-dns, the API server and VictoriaTraces")


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


ROUTER = "infrastructure/base/agent-router"


def check_router():
    spec = find(f"{ROUTER}/envoyproxy.yaml", "EnvoyProxy", "agent-router-proxy").get("spec", {})
    tracing = spec.get("telemetry", {}).get("tracing", {})
    provider = tracing.get("provider", {})
    check(provider.get("type") == "OpenTelemetry" and provider.get("serviceName") == "agent-router",
          "agent-router exports OpenTelemetry spans as service agent-router")
    check(provider.get("backendRefs") == [{"name": "agent-traces-collector", "namespace": "observability", "port": 4317}],
          "agent-router's spans go to the collector's gRPC port (EG 1.9 exports gRPC only)")
    check(tracing.get("tags", {}).get("agent.principal") == "%REQ(X-AR-AGENT)%", "every span names the run's verified principal")
    check(tracing.get("samplingRate") == 100, "every request is sampled")
    egress = find(f"{ROUTER}/network-policy-data-plane.yaml", "CiliumNetworkPolicy", "agent-router-data-plane").get("spec", {}).get("egress", [])
    check(any((r.get("toEndpoints") or [{}])[0].get("matchLabels", {}).get("app.kubernetes.io/name") == "agent-traces-collector"
              and (r.get("toEndpoints") or [{}])[0].get("matchLabels", {}).get("io.kubernetes.pod.namespace") == "observability"
              and r["toPorts"][0]["ports"] == [{"port": "4317", "protocol": "TCP"}] for r in egress),
          "the data plane may reach the collector's :4317")


VM_VALUES = "observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml"
# The AgentRun XRD's status.phase enum (crossplane-configuration apis/agentrun/definition.yaml).
PHASES = ["Pending", "Running", "Succeeded", "Failed", "BudgetExhausted", "Revoked"]


def check_ksm():
    cm = find(VM_VALUES, "ConfigMap", "vm-common-helm-values")
    ksm = yaml.safe_load(cm.get("data", {}).get("values.yaml", "{}")).get("kube-state-metrics", {})
    check(ksm.get("rbac", {}).get("extraRules") == [{"apiGroups": ["cloud.ogenki.io"], "resources": ["agentruns"], "verbs": ["list", "watch"]}],
          "KSM reads agentruns, list and watch only")
    crs = ksm.get("customResourceState", {})
    res = (crs.get("config", {}).get("spec", {}).get("resources") or [{}])[0]
    check(crs.get("enabled") is True and res.get("groupVersionKind") == {"group": "cloud.ogenki.io", "version": "v1alpha1", "kind": "AgentRun"},
          "custom-resource state covers AgentRun")
    check(res.get("metricNamePrefix") == "agentrun", "the series are agentrun_*")
    check(res.get("labelsFromPath", {}).get("run_id") == ["status", "runId"], "every agentrun_* series carries run_id")
    metrics = {m["name"]: m["each"] for m in res.get("metrics", [])}
    want = {"info", "status_phase", "outcome_info", "pull_request_info", "usage_tokens", "budget_max_tokens",
            "started_timestamp_seconds", "finished_timestamp_seconds"}
    check(set(metrics) == want, f"agentrun metrics are {sorted(want)}, got {sorted(metrics)}")
    check(metrics.get("status_phase", {}).get("stateSet", {}).get("list") == PHASES, "status_phase lists every XRD phase")
    info = metrics.get("info", {}).get("info", {}).get("labelsFromPath", {})
    check(info.get("tier") == ["metadata", "labels", "agents.ogenki.io/tier"], "agentrun_info carries the run's tier (O23)")
    check(metrics.get("outcome_info", {}).get("info", {}).get("labelsFromPath") == {"reason": ["status", "reason"]},
          "outcome_info reads status.reason alone (a missing path drops the whole series)")
    check(metrics.get("pull_request_info", {}).get("info", {}).get("labelsFromPath") == {"pull_request": ["status", "pullRequest"]},
          "pull_request_info reads status.pullRequest alone, so a successful run still emits it")
    check(metrics.get("usage_tokens", {}).get("gauge", {}).get("path") == ["status", "usage", "tokens"], "usage_tokens reads status.usage.tokens")
    check(metrics.get("budget_max_tokens", {}).get("gauge", {}).get("path") == ["spec", "budget", "maxTokens"], "budget_max_tokens reads spec.budget.maxTokens")
    check(metrics.get("started_timestamp_seconds", {}).get("gauge", {}).get("path") == ["status", "startedAt"], "started_timestamp_seconds reads status.startedAt")
    check(metrics.get("finished_timestamp_seconds", {}).get("gauge", {}).get("path") == ["status", "finishedAt"], "finished_timestamp_seconds reads status.finishedAt")


DASHBOARDS = "observability/base/agent-platform"


def dashboard(rel, name):
    d = find(rel, "GrafanaDashboard", name)
    check(not re.search(r"(?<!\$)\$\{", (ROOT / rel).read_text()), f"{rel}: every ${{…}} is written $${{…}} for Flux")
    check(d.get("spec", {}).get("folderRef") == "agents", f"{rel}: in the agents folder (O10)")
    try:
        return json.loads(d.get("spec", {}).get("json", "{}").replace("$$", "$"))
    except json.JSONDecodeError as exc:
        errors.append(f"{rel}: invalid JSON: {exc}")
        return {}


def titled(board):
    return {p["title"]: p for p in board.get("panels", [])}


def check_run_dashboard():
    board = dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-run.yaml", "agent-run")
    check(board.get("uid") == "agent-run", "uid agent-run: task agent:run, SP2 and SP3 link to it")
    check("run" in [v["name"] for v in board.get("templating", {}).get("list", [])], "a `run` variable")
    panels = titled(board)
    want = {"Run", "Duration", "Tokens vs budget", "Phase", "Step log", "Model calls through agent-router",
            "MCP calls", "Errors", "Tokens in / out", "Cost (USD)", "Model latency p50 / p95", "Error rate",
            "Steps", "Trace (agent-harness)", "agent-router spans"}
    check(want <= set(panels), f"missing panels: {sorted(want - set(panels))}")
    for title in ("Trace (agent-harness)", "agent-router spans"):
        check(panels.get(title, {}).get("datasource") == {"type": "jaeger", "uid": "VictoriaTraces"}, f"{title} reads VictoriaTraces")
    for title in ("Step log", "Model calls through agent-router", "MCP calls", "Errors", "Steps"):
        check(panels.get(title, {}).get("datasource", {}).get("type") == "victoriametrics-logs-datasource", f"{title} reads VictoriaLogs")
    targets = json.dumps([t for p in board.get("panels", []) for t in p.get("targets", [])])
    check('run_id=\\"${run}\\"' in targets and "xplane-run-${run}" in targets and "agent.run_id=${run}" in targets,
          "the panels filter on the run: KSM run_id, the pod and principal, the span tag")


def check_run_trace_link():
    panels = titled(dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-run.yaml", "agent-run"))
    names = [n for tr in panels.get("Run", {}).get("transformations", []) if tr["id"] == "filterFieldsByName"
             for n in tr["options"]["include"]["names"]]
    check("tier" in names, "the run page shows the run's tier (O23)")
    step = json.dumps(panels.get("Step log", {}).get("targets", []))
    check("extract_regexp" in step and "rename trace_id as log.trace_id" in step,
          "a step line links to its trace through the log.trace_id derived field (O22)")
    m = re.search(r'extract_regexp "([^"]*)"', panels.get("Step log", {}).get("targets", [{}])[0].get("expr", ""))
    own, decoy = "a" * 32, "b" * 32
    line = f"agent-run step 3: terminal | echo trace_id={decoy} | x | trace_id={decoy} | trace_id={own}"
    got = re.search(m[1], line) if m else None
    check(got is not None and got["trace_id"] == own, "the trace id is the line's last field, not agent-written text")


def check_fleet_dashboard():
    board = dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-fleet.yaml", "agent-fleet")
    check(board.get("uid") == "agent-fleet", "uid agent-fleet")
    panels = titled(board)
    check({"Runs", "Runs by phase", "Tokens per run", "Trace pipeline (agent-traces-collector)"} <= set(panels), "the fleet panels")
    links = json.dumps(panels.get("Runs", {}).get("fieldConfig", {}))
    check("/d/agent-run/agent-run?var-run=${__value.text}" in links, "one click from a run_id opens its Agent run page (SO-1)")


def check_fleet_tier():
    panels = titled(dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-fleet.yaml", "agent-fleet"))
    check({"Tier vs tokens and steps per run", "Tokens by tier"} <= set(panels), "tier vs spend panels (O23)")
    targets = json.dumps(panels.get("Tier vs tokens and steps per run", {}).get("targets", []))
    check("stats by (run_id) count() as steps" in targets and "agentrun_info" in targets,
          "tier, tokens and steps joined on run_id")


CHECKS = [check_collector, check_reference_grant, check_router, check_ksm, check_run_dashboard, check_run_trace_link, check_fleet_dashboard, check_fleet_tier]

for run in CHECKS:
    run()
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
