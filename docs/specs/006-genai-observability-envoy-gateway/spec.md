# Spec: GenAI observability — Envoy AI Gateway v1.0 token metrics + traces into the VictoriaMetrics stack

**ID**: SPEC-006
**Issue**: [#1572](https://github.com/Smana/cloud-native-ref/issues/1572)
**Status**: draft
**Type**: platform
**Created**: 2026-07-12
**Last updated**: 2026-07-12

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Wire the Envoy AI Gateway v1.0 native GenAI telemetry into the platform's VictoriaMetrics stack: scrape the gateway's OpenTelemetry GenAI metrics (per-model token usage, request rate, gateway-side latency) with a VMPodScrape/VMServiceScrape, expose them on a dedicated `grafana-dashboard-gateway.yaml`, and — if it proves straightforward against VictoriaTraces' OTLP ingest — push GenAI request traces from the gateway extproc. The platform currently has **zero** gateway-level LLM telemetry; token usage, per-model request rates, gateway TTFT, and canary-split attribution are all invisible.

---

## Problem

The Envoy AI Gateway (`ai-gateway`/`envoy-ai-gateway-system`, HTTP/8080) is the single front door for every OpenAI-compatible request into the vLLM fleet, yet nothing observes it. `infrastructure/base/envoy-ai-gateway/envoyproxy.yaml` carries **no** telemetry block, `helmrelease.yaml` ships controller-only values with no metrics/tracing export, and no OTel collector is deployed. Today the LLM dashboard (`apps/base/ai/llm/grafana-dashboard.yaml`) derives everything from `vllm:*` engine metrics scraped per-model — so token *cost* and request *shape* are only visible after the request reaches an engine, never at the gateway that fans traffic across models, canaries, and (soon) fallbacks.

Concretely, three questions cannot be answered today:
1. **Token spend per model** — how many input/output tokens each model burns through the gateway, independent of which pod served them.
2. **Gateway-level request health** — per-model request rate, error rate, and time-to-first-token as seen at the front door (the dashboard's only gateway panel is a raw `envoy_cluster_upstream_rq_xx` count with no model dimension).
3. **Canary attribution** — SPEC-002 ships a weighted LoRA canary (`modelNameOverride` rewrites `body.model` at the gateway) with an **open question**: does gateway token telemetry attribute canary traffic to the overridden adapter name or the base model? Without gateway metrics this is unanswerable, and the SPEC-002 e2e task (T010) is left with a manual `vllm:lora_requests_info` proxy.

Now: SPEC-002 lands weighted canary routing on this same branch/PR; shipping the observability that makes canary rollouts *legible* alongside it closes that open question with a real signal instead of an inference.

---

## User Stories

### US-1: Per-model token + request telemetry at the gateway (Priority: P1)

As a **platform operator running the LLM fleet**, I want **the gateway's GenAI token and request metrics scraped into VictoriaMetrics and shown on a dashboard**, so that **I can see token spend, request rate, and gateway latency per model without inferring it from engine-side `vllm:*` counters**.

**Acceptance Scenarios**:
1. **Given** the AI Gateway is serving traffic, **When** I query VictoriaMetrics for `gen_ai_client_token_usage_sum`, **Then** the series exists, carries a `gen_ai_request_model` label, and increments as requests flow.
2. **Given** the gateway dashboard, **When** I open it in Grafana, **Then** panels render token usage (input/output) per model, request rate + error rate per model, and gateway latency percentiles — sourced from `gen_ai.*` metrics, not `vllm:*`.
3. **Given** the default (LLM-platform-suspended) cluster, **When** Flux reconciles, **Then** the scrape resource and dashboard apply with no error even though no gateway traffic exists yet (no data ≠ broken).

### US-2: Canary attribution answered from the gateway (Priority: P1)

As the **SPEC-002 canary owner**, I want **the gateway token metrics to carry both the client-requested model name and the served (overridden) model name**, so that **I can prove what fraction of `xplane-qwen-coder` token spend the `sql-dpo` adapter actually served, from the gateway's own signal**.

**Acceptance Scenarios**:
1. **Given** a 10% `sql-dpo` canary active on `xplane-qwen-coder` and ≥50 requests sent for `xplane-qwen-coder`, **When** I split `gen_ai_client_token_usage_sum` by the model-name label(s), **Then** the canary vs base attribution is answerable from the metric labels alone (documented which label — `gen_ai_original_model` vs `gen_ai_request_model` — carries the override).
2. **Given** the same traffic, **When** the gateway dashboard's canary panel renders, **Then** it shows base-vs-canary token share for the qwen-coder split.

### US-3: GenAI request traces in VictoriaTraces (Priority: P3 — conditional)

As a **platform operator debugging a slow or failing LLM request**, I want **the gateway to emit GenAI request spans into VictoriaTraces**, so that **I can trace an OpenAI-compatible request through the gateway with OpenInference attributes**.

**Acceptance Scenarios**:
1. **Given** tracing enabled on the extproc and a chat completion sent through the gateway, **When** I open the VictoriaTraces datasource in Grafana, **Then** a span for the request is visible with model/token attributes.

> US-3 is explicitly conditional on CL-4: if OTLP export from the extproc to VictoriaTraces' non-standard ingest path is not straightforward in v1.0's `extraEnvVars` surface, US-3/FR-006/SC-005 are descoped to a follow-up spec and this spec ships metrics-only.

---

## Requirements

### Functional

- **FR-001**: The AI Gateway MUST expose its GenAI metrics (`gen_ai.client.token.usage`, `gen_ai.server.request.duration`, `gen_ai.server.time_to_first_token`, `gen_ai.server.time_per_output_token`) in Prometheus format, scraped natively (VM-native, no OTLP-metrics push — CL-1). If v1.0 exposes them by default, this is a verify step; if a helm value or `EnvoyProxy` telemetry setting is required to turn them on, it MUST be set in `infrastructure/base/envoy-ai-gateway/`.
- **FR-002**: A `VMPodScrape` (or `VMServiceScrape` if the extproc metrics port is fronted by a Service) MUST be added under `infrastructure/base/envoy-ai-gateway/` selecting the pod/port that exposes `gen_ai.*` metrics, and MUST join that directory's `kustomization.yaml`. It MUST scrape the extproc/data-plane workload in `envoy-ai-gateway-system` (or `envoy-gateway-system` — whichever pod emits the metrics, verified at implementation time — CL-2).
- **FR-003**: The scraped metrics MUST retain a per-model label (`gen_ai_request_model` and the override-carrying label) sufficient to answer canary attribution (US-2). The spec MUST document which label carries the client-requested name vs the `modelNameOverride`-rewritten served name.
- **FR-004**: A new `grafana-dashboard-gateway.yaml` GrafanaDashboard MUST be added next to `apps/base/ai/llm/grafana-dashboard.yaml` (kept separate so the vLLM engine dashboard stays focused — CL-3) with panels for: token usage per model (input/output), request rate + error rate per model, canary-vs-base token attribution for the qwen-coder split, and gateway latency percentiles (from `gen_ai.server.request.duration` / `time_to_first_token`). All Grafana variables MUST use `$${var}` (double-dollar) escaping to survive Flux postBuild substitution.
- **FR-005**: If the `envoy-ai-gateway-system` (or extproc-hosting) namespace runs a **default-deny** CiliumNetworkPolicy on the metrics-emitting pod, an ingress allow rule for the vmagent scrape MUST be added so scraping is not silently DROPPED. (`network-policy.yaml` today declares no ingress rule on the controller for a metrics port and none on the data-plane here — the emitting pod's CNP must be checked and, if default-deny, extended.)
- **FR-006** (conditional — CL-4): The gateway extproc SHOULD emit GenAI request traces via OTLP directly to VictoriaTraces (`victoria-traces-vt-single-server.observability`) with **no new OTel collector** (CL-1), configured via the chart's `extProc.extraEnvVars` (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_METRICS_EXPORTER=none`, `OTEL_SERVICE_NAME`). This is gated on verifying the extproc OTLP exporter can target VictoriaTraces' non-standard ingest path (`/insert/opentelemetry/v1/traces`, port 10428) or its OTLP/gRPC listener (`:4317`, which must be enabled on VictoriaTraces). If neither is straightforward without an intermediary collector, FR-006 is descoped to a follow-up (constitution §5: the VM stack is the standard; a collector is extra moving parts we decline here).
- **FR-007**: No composition/XRD change. The InferenceService module (`infrastructure/base/crossplane/configuration/kcl/inference-service/`) MUST NOT be touched — gateway telemetry is cluster-scoped and label-driven, not per-claim.

### Non-Goals

- **vLLM-level (engine-side) OTel request tracing** — per-request spans *inside* vLLM (needs engine `--otlp-*` flags + a collector). The existing `vllm:*` metrics scrape and dashboard stay as-is; gateway telemetry is additive.
- **A new OpenTelemetry Collector deployment** (CL-1) — metrics are Prometheus-scraped; traces (if in scope) push directly to VictoriaTraces.
- **New alerting / VMRules** on gateway metrics — the SLO VMRule (`vmrule-llm-slo.yaml`) stays engine-based; gateway-metric alerts are a follow-up.
- **Cost/$ attribution** (token→dollar mapping per model/provider) — out of scope; this ships the token counts that a cost layer would later consume.
- **Access-log ingestion** into VictoriaLogs — the gateway's AI access-log sink (model/token metadata as structured logs) is a separate follow-up.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: After sending ≥1 chat completion through the gateway, VictoriaMetrics returns a non-empty `gen_ai_client_token_usage_sum` series carrying a `gen_ai_request_model` label — verified via a VM query (MCP `query_prometheus` or `vmui`).
- **SC-002**: The gateway `VMPodScrape`/`VMServiceScrape` target shows `up == 1` in VictoriaMetrics (`up{...envoy-ai-gateway...} == 1`) — the scrape is healthy, not DROPPED.
- **SC-003**: The `grafana-dashboard-gateway.yaml` GrafanaDashboard reconciles to `Ready` (`kubectl get grafanadashboard -n llm` → no error) and every panel `datasource` is a metrics datasource (no `vllm:*`-only panel duplicated); the dashboard JSON lints (valid JSON, `$${var}` escaping present on all templating variables).
- **SC-004**: With a 10% `sql-dpo` canary active and ≥50 `xplane-qwen-coder` requests, the canary-vs-base token attribution is derivable from `gen_ai_*` label(s) and matches (within binomial tolerance) the `vllm:lora_requests_info` split SPEC-002/SC-002 measures — and the spec/README records which label carries the override. This **closes the SPEC-002 open question**.
- **SC-005** (conditional — CL-4): If FR-006 is in scope, a GenAI request span for a gateway chat completion is visible in VictoriaTraces (Grafana `VictoriaTraces` Jaeger datasource returns the trace) with model/token attributes. If FR-006 was descoped, this SC is marked N/A in the plan with the descope reason.
- **SC-006**: All added/changed static manifests pass `kubeconform` and `hubble observe --pod envoy-ai-gateway-system/<extproc-pod> --verdict DROPPED --last 50` shows no scrape-related drops after the CNP rule (FR-005) is applied.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] Observation (non-blocking, resolved during implementation): exact pod + port that exposes `gen_ai.*` metrics in v1.0 (extproc pod in `envoy-ai-gateway-system` vs Envoy data-plane in `envoy-gateway-system`) and whether it is Service-fronted — determines `VMPodScrape` vs `VMServiceScrape` (FR-002). Verify with `kubectl get pods -n envoy-ai-gateway-system -o json | jq` + a `curl` of the candidate metrics port; record in the plan.

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — VM-native path: Prometheus-scrape for metrics, direct OTLP push for traces, **no OTel collector**.
- CL-2 — Scrape the pod that actually emits `gen_ai.*` (extproc vs data-plane), verified at implementation; `VMPodScrape` unless Service-fronted.
- CL-3 — Dashboard: a NEW `grafana-dashboard-gateway.yaml` sibling, not an extension of the vLLM dashboard.
- CL-4 — Traces are conditional: ship only if OTLP export from the extproc to VictoriaTraces' non-standard ingest is straightforward; else descope to a follow-up.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md) — §5 Observability (VictoriaMetrics/VMServiceScrape, VictoriaLogs)
- Observability rules: [.claude/rules/observability.md](../../../.claude/rules/observability.md) — `$${var}` dashboard escaping, logs datasource
- CNP rules: [.claude/rules/cilium-network-policies.md](../../../.claude/rules/cilium-network-policies.md) — scrape-ingress on default-deny
- Related spec (same PR): [SPEC-002 — composition-owned AI Gateway routing + LoRA canary](../002-composition-owned-gateway-routing/spec.md) — this spec closes its open question on canary token attribution
- Envoy AI Gateway v1.0 observability: <https://aigateway.envoyproxy.io/docs/capabilities/observability/> (metrics: `gen_ai.client.token.usage`, `gen_ai.server.request.duration`, `gen_ai.server.time_to_first_token`, `gen_ai.server.time_per_output_token`; labels `gen_ai_request_model` / `gen_ai_original_model` / `gen_ai_response_model`, `gateway_envoyproxy_io_owning_gateway_name`; tracing via `extProc.extraEnvVars` OTLP)
- VictoriaTraces OTLP ingest: <https://docs.victoriametrics.com/victoriatraces/data-ingestion/opentelemetry/> (`http://<vt>:10428/insert/opentelemetry/v1/traces` OTLP/HTTP; OTLP/gRPC `:4317` via `-otlpGRPCListenAddr`)
