# Plan: GenAI observability — Envoy AI Gateway v1.0 token metrics + traces into the VictoriaMetrics stack

**Spec**: [SPEC-006](spec.md)
**Status**: draft
**Last updated**: 2026-07-12

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

This is a **static-manifest** feature — no KCL/composition/XRD work (FR-007). Everything lands as YAML under `infrastructure/base/envoy-ai-gateway/` (scrape + CNP + optional trace config) and `apps/base/ai/llm/` (dashboard), validated with `kubeconform` (not `validate-kcl-compositions.sh`).

### Verified current state (cited)

- **Gateway**: `Gateway/ai-gateway` in `envoy-ai-gateway-system` (HTTP/8080, `gateway.yaml`); data-plane shape from `EnvoyProxy/ai-gateway-proxy` (`envoyproxy.yaml`) — **no telemetry block today**. Data-plane Service pinned to `ai-gateway` (`ClusterIP`). Controller-only helm values (`helmrelease.yaml`) — **no metrics/tracing export**. `network-policy.yaml` is default-deny: the controller CNP allows :8081 (probes), :9443 (webhook), :1063 (ext-server); **no metrics-scrape ingress rule anywhere**.
- **Observability stack**: `vmsingle-victoria-metrics-k8s-stack.observability:8428`; `VMServiceScrape`/`VMPodScrape` are the scrape idiom (e.g. `infrastructure/base/vllm-semantic-router/vmservicescrape.yaml` — `port: metrics`, `path: /metrics`, `interval: 30s`). **VictoriaTraces** at `victoria-traces-vt-single-server.observability:10428` (`observability/base/victoria-traces/`, retention 3d), already receiving Flux events via the `otel-traces` notification Provider (`flux/observability/otel-provider.yaml`) — Grafana Jaeger datasource `VictoriaTraces` at `.../10428/select/jaeger`. **No OTel collector deployed.**
- **LLM dashboard**: `apps/base/ai/llm/grafana-dashboard.yaml` (GrafanaDashboard `llm-platform`, ns `llm`, folder `llm`) — all engine-side `vllm:*` + one raw `envoy_cluster_upstream_rq_xx` panel (no model dimension); `$${var}` escaping already used.

### Envoy AI Gateway v1.0 telemetry (verified from docs — cite)

**Metrics** (OpenTelemetry GenAI semconv, Prometheus exposition, on by default):

| Metric | Meaning |
|--------|---------|
| `gen_ai.client.token.usage` (→ `gen_ai_client_token_usage_sum`) | token count; attr `gen_ai_token_type` = input/output/total |
| `gen_ai.server.request.duration` | end-to-end request latency at the gateway |
| `gen_ai.server.time_to_first_token` | gateway-observed TTFT |
| `gen_ai.server.time_per_output_token` | inter-token latency |

Model labels: `gen_ai_request_model` (client-requested name), `gen_ai_original_model`, `gen_ai_response_model` (served name). Gateway label: `gateway_envoyproxy_io_owning_gateway_name` (e.g. `ai-gateway`). Emitted by the **extproc** (external-processor) workload. **Canary attribution seam (US-2/FR-003):** `modelNameOverride` rewrites `body.model` before upstream selection, so `gen_ai_request_model` should carry the client name (`xplane-qwen-coder`) and `gen_ai_response_model` the served/overridden name (`xplane-qwen-coder-sql-dpo`) — **verify empirically in T007 and record the answer** (this is the SPEC-002 open question).

**Tracing** (OpenInference semconv): enabled via chart `extProc.extraEnvVars` — `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_METRICS_EXPORTER=none` (metrics stay Prometheus-scraped), `OTEL_SERVICE_NAME=ai-gateway`. Exporter pushes **directly** to an OTLP endpoint — no collector required. Chat/Completions/Embeddings requests recorded as spans.

**VictoriaTraces OTLP friction (CL-4):** VictoriaTraces' OTLP/HTTP path is **`/insert/opentelemetry/v1/traces`** (non-standard; the SDK's default `OTEL_EXPORTER_OTLP_ENDPOINT` appends `/v1/traces`), or OTLP/gRPC on `:4317` which must be enabled with `-otlpGRPCListenAddr`. So a direct push needs either the full non-standard path in the endpoint env-var **or** enabling the VT gRPC listener. If neither is clean via `extraEnvVars` in v1.0, traces (FR-006/US-3/SC-005) descope to a follow-up.

### Resources Created / Changed

| Resource | Path | Condition | Notes |
|----------|------|-----------|-------|
| `VMPodScrape` (or `VMServiceScrape`) `envoy-ai-gateway-genai` | `infrastructure/base/envoy-ai-gateway/vmscrape.yaml` | Always | Selects the extproc pod/port emitting `gen_ai.*`; joins `kustomization.yaml`. Pod vs Service determined in T001 |
| CNP ingress rule | `infrastructure/base/envoy-ai-gateway/network-policy.yaml` (edit) | If emitting pod is default-deny | Allow vmagent (`observability` ns) → metrics port on the emitting pod (FR-005) |
| `EnvoyProxy` telemetry / helm value | `envoyproxy.yaml` or `helmrelease.yaml` (edit) | Only if metrics are NOT on by default | Verify-first; likely a no-op edit |
| `GrafanaDashboard` `llm-gateway` | `apps/base/ai/llm/grafana-dashboard-gateway.yaml` (new) | Always | Sibling of `grafana-dashboard.yaml`; joins `apps/base/ai/llm/kustomization.yaml`; `$${var}` escaping |
| `extProc.extraEnvVars` trace config | `helmrelease.yaml` (edit) | **Conditional (CL-4)** | OTLP endpoint → VictoriaTraces; only if T006 verification is clean |

### Key Entities

- **Emitting pod**: the AI Gateway **extproc** — must confirm its namespace (`envoy-ai-gateway-system` controller ns vs `envoy-gateway-system` data-plane ns), pod labels, and metrics port before writing the scrape selector (T001, CL-2).
- **Scrape target**: `VMPodScrape` preferred (extproc metrics port may not be Service-fronted); fall back to `VMServiceScrape` if a Service exposes it. `interval: 30s`, matching the semantic-router scrape.
- **Canary label**: whichever of `gen_ai_request_model` / `gen_ai_response_model` carries the `modelNameOverride` value — the load-bearing label for US-2/SC-004.

### Dependencies

- [ ] Envoy AI Gateway v1.0.0 installed (already: `infrastructure/base/envoy-ai-gateway/`)
- [ ] LLM platform released on both gates (Terramate `TM_LLM_PLATFORM_ENABLED`, Flux `llm-platform` Kustomization resumed) for e2e traffic — metrics/dashboard manifests themselves reconcile LLM-free
- [ ] SPEC-002 canary (`gateway.canaries: [{adapter: sql-dpo, weightPercent: 10}]` on `xplane-qwen-coder`) applied for SC-004
- [ ] VictoriaTraces reachable at `victoria-traces-vt-single-server.observability:10428` (already deployed) — only if FR-006 in scope
- [ ] No composition/XRD change; no `ManagedResourceActivationPolicy` change; no Crossplane RBAC change

### Alternatives considered

OTLP-metrics push to VictoriaMetrics via a collector — rejected (CL-1: VM stack is Prometheus-scrape-native; a collector is extra moving parts). Extending the existing vLLM dashboard rather than a sibling — rejected (CL-3: keeps the engine dashboard focused). Making traces mandatory in v1 — rejected (CL-4: VictoriaTraces' non-standard OTLP path makes direct extproc export a verify-first risk).

---

## Implementation Notes

- **Verify-before-write for the scrape (T001)**: `kubectl get pods -n envoy-ai-gateway-system -o json | jq '.items[].metadata.labels'` + `kubectl get pods -n envoy-gateway-system ...`; port-forward the candidate metrics port and `curl /metrics | grep gen_ai` to confirm the endpoint before authoring the selector. Do NOT assume the port.
- **CNP (T003)**: per `.claude/rules/cilium-network-policies.md`, a metrics port that isn't explicitly allowed is silently DROPPED under default-deny. Add an ingress rule `fromEndpoints` the `observability`/vmagent pod → the metrics port on the emitting pod. Verify with `hubble observe --pod <ns>/<extproc> --verdict DROPPED`.
- **Dashboard (T004)**: mirror `grafana-dashboard.yaml` structure — `GrafanaDashboard` in ns `llm`, folder `llm`, `instanceSelector dashboards: grafana`, `allowCrossNamespaceImport: true`. Every templating variable and panel `uid` uses `$${var}` (double-dollar) so Flux postBuild doesn't strip it (`.claude/rules/observability.md`). Metrics datasource only (no logs panel needed here). Lint the embedded JSON before commit.
- **Traces (T006, conditional)**: set `extProc.extraEnvVars` in `helmrelease.yaml` — `OTEL_EXPORTER_OTLP_ENDPOINT` must carry VictoriaTraces' full non-standard path or target the gRPC listener; `OTEL_METRICS_EXPORTER=none` so we don't double-export metrics. If the extproc SDK won't accept the non-standard path and enabling VT's gRPC listener is non-trivial, STOP and descope FR-006 (record in Deviations + a CL if it's a real decision).
- **Rollback**: pure-additive manifests; revert removes the scrape + dashboard (+ trace env-vars). No data-plane behavior change, no composition re-publish.

### File structure (static manifests — NOT a composition)

```
infrastructure/base/envoy-ai-gateway/
├── vmscrape.yaml            # NEW — VMPodScrape/VMServiceScrape for gen_ai.* metrics
├── network-policy.yaml      # EDIT — + scrape-ingress allow rule (if default-deny)
├── helmrelease.yaml         # EDIT (conditional) — extProc.extraEnvVars OTLP trace export
├── envoyproxy.yaml          # EDIT (only if metrics need turning on)
└── kustomization.yaml       # EDIT — + vmscrape.yaml
apps/base/ai/llm/
├── grafana-dashboard-gateway.yaml   # NEW — gateway GenAI dashboard
└── kustomization.yaml               # EDIT — + grafana-dashboard-gateway.yaml
```

### Validation path

- `kubeconform -summary -output json` on every new/changed manifest (VMPodScrape/VMServiceScrape schema, GrafanaDashboard, CiliumNetworkPolicy) — note VM operator + Grafana operator + Cilium CRDs need `-schema-location` for CRD schemas or `-ignore-missing-schemas`
- Dashboard JSON lints as valid JSON; `$${` escaping present on all templating variables
- `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml infrastructure/base/envoy-ai-gateway/` clean
- e2e on the feature-branch cluster: SC-001/002/004/006 (+ SC-005 if traces in scope)

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: Verify exposure & scrape

- [ ] **T001**: Verify which pod/port emits `gen_ai.*` metrics (extproc in `envoy-ai-gateway-system` vs data-plane in `envoy-gateway-system`), whether it's Service-fronted, and its labels; confirm `curl /metrics | grep gen_ai` returns series. If metrics need enabling (helm value / `EnvoyProxy` telemetry), set it (FR-001). Record the verified pod/port/labels in this plan (CL-2).
- [ ] **T002**: Add `VMPodScrape`/`VMServiceScrape` `envoy-ai-gateway-genai` selecting that pod/port; join `kustomization.yaml` (FR-002). Confirm the selector matches with `kubectl get vmpodscrape ... -o yaml` and the target appears in VM.

### Phase 2: Network policy

- [ ] **T003**: Check the emitting pod's CNP; if default-deny, add a scrape-ingress allow rule (vmagent/`observability` → metrics port) to `network-policy.yaml` (FR-005). Verify `up == 1` in VM and `hubble observe --verdict DROPPED` is clean for the scrape path (SC-002, SC-006).

### Phase 3: Dashboard

- [ ] **T004**: Add `apps/base/ai/llm/grafana-dashboard-gateway.yaml` (GrafanaDashboard `llm-gateway`) with token-per-model, request/error rate per model, canary-vs-base attribution, and gateway latency percentile panels; `$${var}` escaping; join `apps/base/ai/llm/kustomization.yaml` (FR-004). Lint the JSON.

### Phase 4: Traces (conditional — CL-4)

- [ ] **T005**: Verify whether the extproc OTLP exporter (`extProc.extraEnvVars`) can target VictoriaTraces' `/insert/opentelemetry/v1/traces` (HTTP) or its gRPC `:4317` listener without a collector. Decide IN/OUT of scope; if OUT, descope FR-006/US-3/SC-005 (Deviations + CL).
- [ ] **T006**: (only if T005 says IN) Set `extProc.extraEnvVars` OTLP env-vars in `helmrelease.yaml` (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_METRICS_EXPORTER=none`, `OTEL_SERVICE_NAME=ai-gateway`) → VictoriaTraces; if VT gRPC needed, enable `-otlpGRPCListenAddr` in `observability/base/victoria-traces/helmrelease-vtsingle.yaml`. Add any egress CNP rule the extproc needs to reach VictoriaTraces.

### Phase 5: e2e & validation (feature-branch cluster)

- [ ] **T007**: e2e SC-001/SC-003/SC-004 — send ≥50 `xplane-qwen-coder` requests with the 10% `sql-dpo` canary; assert `gen_ai_client_token_usage_sum{gen_ai_request_model=...}` in VM; determine which label carries the `modelNameOverride` value and record the canary attribution answer (closes SPEC-002 open question); confirm the dashboard renders. SC-005 if traces in scope.
- [ ] **T008**: `kubeconform` on all new/changed manifests + dashboard JSON lint + `trivy config` clean; `hubble observe --verdict DROPPED` clean (SC-006).

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-12> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (zero gateway-level LLM telemetry; three unanswerable questions; canary attribution open in SPEC-002)
- [x] User stories capture real user needs (US-1 token/request telemetry, US-2 canary attribution, US-3 conditional traces)
- [x] Acceptance scenarios are testable (each maps to an SC with a VM query / Grafana check / hubble command)
- [x] Scope is well-defined (Non-Goals: engine-side OTel tracing, OTel collector, gateway VMRules, cost mapping, access logs)
- [x] Success criteria are measurable (SC-001…006, falsifiable; SC-005 explicitly conditional)

### Platform Engineer

- [x] Design follows existing patterns (VMServiceScrape/VMPodScrape idiom from `vllm-semantic-router`; GrafanaDashboard mirrors `grafana-dashboard.yaml`; VictoriaTraces already wired)
- [x] API is consistent with other observability manifests (VM operator CRs, grafana-operator GrafanaDashboard) — N/A composition API (FR-007: no XRD)
- [x] Resource naming — N/A `xplane-*` (these are platform-owned static manifests, not Crossplane-managed; scrape/dashboard named `envoy-ai-gateway-genai` / `llm-gateway`)
- [x] KCL avoids mutation pattern — N/A (no KCL; static YAML validated with kubeconform, CL-4/FR-007)
- [x] Examples provided — N/A composition; the dashboard + scrape are the artifacts, verified by render/scrape health not example claims

### Security & Compliance

- [x] Zero-trust networking (FR-005: scrape-ingress rule added if the emitting pod is default-deny; verified DROPPED-clean via hubble — SC-006)
- [x] Least-privilege RBAC (no new RBAC; VM operator already scrapes via existing vmagent SA; no Crossplane grant needed — FR-007)
- [x] Secrets via External Secrets (no new secrets; metrics are unauthenticated in-cluster scrape; trace OTLP endpoint is in-cluster plaintext to VictoriaTraces)
- [x] Security context enforced (no new pods; extproc/data-plane pods keep their restricted-PSS context from `envoyproxy.yaml`/`helmrelease.yaml` — only env-vars added in the conditional trace path)
- [x] IAM policies scoped to `xplane-*` (N/A — no AWS resources touched)

### SRE

- [x] Health checks defined (no new pods; scrape health asserted via `up == 1` — SC-002)
- [x] Observability configured (this spec *is* the observability: metrics → VictoriaMetrics via VMPodScrape, dashboard → Grafana, traces → VictoriaTraces conditional)
- [x] Resource requests + limits appropriate (no new pods; VictoriaTraces already sized in `helmrelease-vtsingle.yaml`)
- [x] Failure modes documented (no-data ≠ broken on LLM-suspended cluster — SC-003; silent scrape DROP under default-deny — FR-005; non-standard VT OTLP path — CL-4)
- [x] Recovery / rollback path clear (pure-additive manifests; revert removes scrape + dashboard + trace env-vars — Implementation Notes)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Related spec (same PR): [SPEC-002](../002-composition-owned-gateway-routing/spec.md) — closes its canary token-attribution open question
- Reference scrape: `infrastructure/base/vllm-semantic-router/vmservicescrape.yaml`
- Reference dashboard: `apps/base/ai/llm/grafana-dashboard.yaml`
- VictoriaTraces datasource/ingest: `observability/base/victoria-traces/`, `flux/observability/otel-provider.yaml`
