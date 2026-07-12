# Clarifications Log — GenAI observability: Envoy AI Gateway token metrics + traces into the VictoriaMetrics stack

**Spec**: [SPEC-006](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-12 — Metrics + traces transport: scrape/push and no collector?

**Asked by**: Spec author (adopt-recos directive, 2026-07-12)
**Context**: Envoy AI Gateway v1.0 emits GenAI telemetry in OpenTelemetry format — metrics can be Prometheus-scraped OR OTLP-pushed, and traces are OTLP-only. The platform's constitution (§5) makes VictoriaMetrics/VMServiceScrape the metrics standard and already runs VictoriaTraces (OTLP ingest) with no OpenTelemetry Collector anywhere in the stack. The question is whether to introduce a collector to normalise both signals.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Metrics via Prometheus-scrape (VMPodScrape/VMServiceScrape), traces via direct OTLP push to VictoriaTraces, **no collector** | VM-native; matches every existing scrape; zero new pods; extproc OTLP exporter targets an endpoint directly (docs: no collector needed) | Traces limited by whatever the extproc `extraEnvVars` OTLP surface allows |
| B | Deploy an OTel Collector as a hub for both metrics (OTLP→remote-write) and traces | Single normalisation point; future-proof for more OTLP sources | Extra long-lived pod + CNP + config; constitution treats the VM stack as the standard; over-machinery for one gateway |
| C | OTLP-push metrics too (skip Prometheus scrape) | One transport for both | Loses VM-native scrape-health (`up`), pushes against the grain of every other scrape in the repo |

**Decision**: A — Prometheus-scrape for metrics, direct OTLP push for traces, **no OTel collector**.
**Rationale**: The extproc exposes `gen_ai.*` in Prometheus format by default and its trace exporter can target an OTLP endpoint directly (verified in the v1.0 tracing docs — Phoenix example points straight at a service, no collector). A collector would be the only moving part this feature adds and buys nothing at one-gateway scale. Constitution §5 makes scrape the metrics norm.
**Decided by**: User (adopt-recos, 2026-07-12)
**References**: constitution §5.1 (VictoriaMetrics/ServiceMonitor); Envoy AI Gateway tracing docs (`extProc.extraEnvVars` OTLP, no collector); `infrastructure/base/vllm-semantic-router/vmservicescrape.yaml`

## CL-2 — 2026-07-12 — Which pod does the scrape target, and VMPodScrape vs VMServiceScrape?

**Asked by**: Spec author (adopt-recos directive, 2026-07-12)
**Context**: v1.0 GenAI metrics are emitted by the **extproc** (external-processor) workload, but the AI Gateway spans two namespaces — the controller runs in `envoy-ai-gateway-system` while the Envoy data-plane (and its injected body-parser/extproc sidecar) runs in `envoy-gateway-system`. The exact metrics pod + port + whether it's Service-fronted must be confirmed before authoring a selector, or the scrape silently targets nothing.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `VMPodScrape` selecting the extproc pod by label on its metrics port, chosen after verifying pod/port at implementation | Works whether or not a Service exists; matches "scrape the pod that emits" | Requires a verify step (T001) before the selector is correct |
| B | `VMServiceScrape` assuming a metrics Service exists | Mirrors the semantic-router pattern exactly | The extproc metrics port may not be Service-fronted → empty target |
| C | Annotation-based scrape (`prometheus.io/scrape`) | No CR | Not the repo idiom; VM operator prefers explicit CRs |

**Decision**: A — `VMPodScrape` by default, verified pod/port/labels first (T001); fall back to `VMServiceScrape` only if a Service actually exposes the metrics port.
**Rationale**: The emitting workload and whether it's Service-fronted are unknown until inspected on the live cluster; committing a selector blind risks a silent no-op scrape. `VMPodScrape` is the safe default for a sidecar/extproc metrics port. The plan makes T001 a hard verify-before-write gate.
**Decided by**: User (adopt-recos, 2026-07-12)
**References**: Envoy AI Gateway metrics docs (extproc emits `gen_ai.*`; label `gateway_envoyproxy_io_owning_gateway_name`); `infrastructure/base/envoy-ai-gateway/network-policy.yaml` (two-namespace architecture note); VM operator `VMPodScrape`/`VMServiceScrape`

## CL-3 — 2026-07-12 — Extend the vLLM dashboard or add a sibling gateway dashboard?

**Asked by**: Spec author (adopt-recos directive, 2026-07-12)
**Context**: `apps/base/ai/llm/grafana-dashboard.yaml` is a focused engine-side view (vLLM throughput/latency, KV cache, KEDA replicas, error logs). Gateway GenAI metrics (`gen_ai.*`) are a different signal source and audience (front-door token/cost + canary attribution vs per-engine health).

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | New `grafana-dashboard-gateway.yaml` sibling | Keeps the vLLM dashboard focused; independent evolution; clear front-door vs engine split | Two dashboards to open for a full picture |
| B | Add panels to the existing `grafana-dashboard.yaml` | One-stop view | Bloats an already-large dashboard; mixes gateway and engine semantics; larger diff on a shared file |
| C | Grafana row inside the existing dashboard | Middle ground | Still couples the two signal sources' lifecycle |

**Decision**: A — a new `grafana-dashboard-gateway.yaml` next to the vLLM dashboard.
**Rationale**: Front-door (token spend, request/error rate per model, canary attribution, gateway latency) and engine internals are distinct concerns with distinct audiences; a sibling keeps each dashboard legible and lets the gateway view evolve without touching the engine one. Both use `$${var}` escaping and the same folder/instance selector.
**Decided by**: User (adopt-recos, 2026-07-12)
**References**: `apps/base/ai/llm/grafana-dashboard.yaml`; `.claude/rules/observability.md` (`$${var}` escaping, metrics vs logs datasource)

## CL-4 — 2026-07-12 — Are gateway traces in scope for v1, given VictoriaTraces' non-standard OTLP path?

**Asked by**: Spec author (adopt-recos directive, 2026-07-12)
**Context**: v1.0 enables tracing by setting `OTEL_EXPORTER_OTLP_ENDPOINT` on the extproc via `extProc.extraEnvVars`; the SDK exporter appends the **standard** OTLP path (`/v1/traces`). VictoriaTraces' OTLP/HTTP ingest path is **non-standard** — `/insert/opentelemetry/v1/traces` (port 10428) — or OTLP/gRPC on `:4317` which must be explicitly enabled with `-otlpGRPCListenAddr`. So a direct push needs either the full non-standard path embedded in the endpoint env-var (which some SDK exporters override, some don't) or enabling VT's gRPC listener. This is a real compatibility risk, not a given.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Traces conditional — ship metrics now; ship traces only if T005 confirms the extproc OTLP exporter can reach VictoriaTraces without a collector; else descope to a follow-up | Metrics (the headline signal) land regardless; no collector smuggled in through the back door; honest about the path risk | Traces may slip to a follow-up spec |
| B | Traces mandatory in v1 | Complete telemetry now | Forces either a collector (violates CL-1) or a shim if the non-standard path blocks direct export; risks blocking the whole spec on a compatibility unknown |
| C | Drop traces entirely, metrics-only forever | Simplest | Forecloses a genuinely useful signal (per-request GenAI spans) the gateway emits for free |

**Decision**: A — traces are conditional (US-3/FR-006/SC-005 gated on T005). Metrics + dashboard are unconditional; traces ship iff direct extproc→VictoriaTraces OTLP export is straightforward, otherwise they descope to a follow-up spec with the reason recorded in the plan's Deviations.
**Rationale**: The metrics path is verified and low-risk; the traces path hinges on an OTLP endpoint-path incompatibility that can only be settled on the cluster. Gating traces keeps the valuable, certain part of the spec unblocked while refusing to introduce a collector (CL-1) just to bridge a path mismatch. Consistent with the constitution's preference for the VM stack as the standard and minimal moving parts.
**Decided by**: User (adopt-recos, 2026-07-12)
**References**: Envoy AI Gateway tracing docs (`extProc.extraEnvVars`, OTLP direct export); VictoriaTraces OTLP ingest docs (`/insert/opentelemetry/v1/traces` HTTP; `:4317` gRPC via `-otlpGRPCListenAddr`); CL-1 (no collector)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
