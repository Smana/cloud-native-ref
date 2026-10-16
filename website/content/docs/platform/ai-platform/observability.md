---
title: Observability
weight: 50
description: "What the AI platform emits and where to read it: vLLM, KEDA and gateway metrics for serving; per-run traces, step logs, gen_ai metrics and AgentRun state for agents."
lastVerified: 2026-10-16
---

Both halves land in the platform's Victoria stack and Grafana; nothing here runs a second
telemetry pipeline. Serving is watched per model, agents per run. Open findings on this page's
signals are on the [status page]({{< relref "/docs/platform/ai-platform/status.md#live-findings" >}}).

```mermaid
flowchart LR
  subgraph serving["Serving"]
    V["vLLM pods<br/>vllm:* :8000"]
    AIG["ai-gateway extproc<br/>gen_ai_* :1064"]
  end
  subgraph agents["Agents"]
    RUN["Agent run<br/>OTLP spans, step log"]
    AGW["agentgateway agent-router<br/>access log, gen_ai_* :15020"]
    KSM["kube-state-metrics<br/>AgentRun state"]
  end
  VM[("VictoriaMetrics")]
  VL[("VictoriaLogs")]
  VT[("VictoriaTraces")]
  COL["agent-traces-collector<br/>allowlisted metadata"]
  KEDA["KEDA<br/>three triggers"]
  G["Grafana"]
  V --> VM
  AIG --> VM
  VM --> KEDA
  RUN --> COL --> VT
  RUN -->|step log| VL
  AGW --> VL
  AGW --> VM
  KSM --> VM
  VM --> G
  VL --> G
  VT --> G
```

## Serving

| Signal | Source | Read it in |
|---|---|---|
| Engine metrics | Each vLLM pod's `/metrics` on port 8000, `vllm:*` labelled by `model_name`, scraped by the `VMServiceScrape` each claim renders (`observability.metrics.interval`, `30s` on all four) | *LLM Platform — Self-hosted vLLM Fleet*: replicas, queue depth, throughput, TTFT and decode latency, GPU KV-cache usage, prefix-cache hit rate, vLLM error logs |
| Gateway metrics | The AI Gateway extproc's `/metrics` on port 1064, `gen_ai_*` (OpenTelemetry semantic conventions) | *LLM Gateway — Envoy AI Gateway GenAI Telemetry*: token spend per model, base-vs-canary attribution, TTFT and time per output token |
| Autoscaling | KEDA's three triggers query the same `vllm:*` series every 15 s | [Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/serving/autoscaling-and-gpu.md" >}}) |

Both dashboards live in the Grafana folder `llm` (`apps/base/ai/llm/grafana-folder.yaml`), which
only exists once the opt-in umbrella is resumed.

**Alerts** are lagging signals, deliberately not scale triggers:

| File | Alerts |
|---|---|
| `apps/base/ai/llm/vmrule-llm-slo.yaml` | Serving: sustained queue depth, time to first token breached, a replica scaled to zero. Gateway: `gen_ai` telemetry missing, scrape down, high error rate, canary error-rate and latency regressions |
| `apps/base/ai/llm/vmrule-ai-fleet.yaml` | Fleet abort rate, Semantic Router down, Promptfoo regression and staleness |

## Agents

One trace, one step log and one dashboard page per run, so a human can open any run and see where
it stands, what it did, what it cost and where its time went.

| Component | Software | What it does |
|---|---|---|
| Logs | [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) | Every run's step log and every gateway call, attributed to the run |
| Metrics | [VictoriaMetrics](https://victoriametrics.com) | Tokens, cost, latency and errors per run, and each `AgentRun`'s state through kube-state-metrics |
| Traces | [VictoriaTraces](https://docs.victoriametrics.com/victoriatraces/), behind an OpenTelemetry Collector that keeps only allowlisted metadata | One trace per run: steps, model calls and tool calls. Metadata only: no prompts or outputs |
| Dashboards | [Grafana](https://grafana.com) | `agent-run`, one page per run, and `agent-fleet`, the overview |

The full transcript (prompts and outputs) stays in the
[room]({{< relref "/docs/platform/ai-platform/agents/rooms.md" >}}), behind room access. Alerting
on runs belongs to the factory's rules, per the
[observability design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-27-agent-observability-design.md).
Which question each signal answers, from a developer's seat, is in the
[user guide]({{< relref "/docs/platform/ai-platform/agents/user-guide.md#observability-what-you-can-inspect" >}}).

### The agent gateway's signals

agentgateway ([gateways]({{< relref "/docs/platform/ai-platform/gateways.md#the-agent-gateway-agent-runs" >}}))
emits under its own names. The scrape (`infrastructure/base/agent-gateway/vmpodscrape.yaml`) renames
only the families the run meter, the budget alerts and the run page read, so they keep the `gen_ai_*`
contract:

| agentgateway emits | Stored as |
|---|---|
| `agentgateway_gen_ai_client_token_usage_{bucket,sum,count}` | `gen_ai_client_token_usage_{bucket,sum,count}` |
| `gen_ai_token_type="input_cache_read"` | `gen_ai_token_type="cached_input"` |
| `gen_ai_token_type="input_cache_write"` | `gen_ai_token_type="cache_creation_input"` |
| `agentgateway_gen_ai_server_request_duration_*` | `gen_ai_server_request_duration_seconds_*` |
| `gen_ai_system` | `gen_ai_provider_name` |

Every other series keeps its `agentgateway_` name, and all carry `namespace="agent-gateway"`, which
keeps them apart from `ai-gateway`'s. Without the cache relabel the meter would price every cache read
at the input rate.

Access logs are JSON with no `msg`, so LogsQL selects by pod labels and `log.*` fields:

```logsql
kubernetes.pod_namespace:"agent-gateway" AND kubernetes.pod_labels.gateway.networking.k8s.io/gateway-name:"agent-router"
  | unpack_json | log.x_ar_agent:"system:serviceaccount:agents:<run>"
```

Useful fields: `log.http.status`, `log.http.path`, `log.reason`, `log.route`, `log.x_ar_agent`,
`log.mcp.method.name`, `log.gen_ai.tool.name`.

Alerts in `observability/base/agent-platform/vmrule.yaml`, read on the **Agent gateway** dashboard
(`uid: agent-gateway`):

| Alert | Fires when |
|---|---|
| `AgentRouterMetricContractBroken` | Model calls succeed but no `gen_ai_client_token_usage` series follows, or a token type outside the four the meter reads appears: an upgrade renamed something the relabel maps |
| `AgentGateway5xxRatioHigh` | Over 5% of requests answer 5xx for 10 minutes |
| `AgentGatewayModelErrorRatioHigh` | Over 10% of model calls fail for 10 minutes |
| `AgentGatewayUnauthorizedBurst` | More than 20 refusals with reason `JwtAuth` or `Authorization` in 5 minutes |
| `AgentRateLimitDown` | `agent-ratelimit` is down: budgets B1–B2 count nothing while the router fails open |
