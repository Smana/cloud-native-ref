# Clarifications Log — Per-InferenceService InferencePool + Endpoint Picker (GAIE v1.5.0) smart routing behind Envoy AI Gateway

**Spec**: [SPEC-004](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-12 — <one-line question>

**Asked by**: <role or user>
**Context**: <1–3 sentences: why this decision matters; what is constrained>

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | <answer> | <pro> | <con> |
| B | <answer> | <pro> | <con> |
| C | <answer> | <pro> | <con> |

**Decision**: <Option letter + answer>
**Rationale**: <Why — tie back to constitution, existing patterns, or SC-XXX>
**Decided by**: <who — conversation / PR reviewer / ADR>
**References**: <links to ADR, similar spec, vendor doc>

-->

---

## CL-1 — 2026-07-12 — How is endpoint-picker opt-in expressed on the claim?

**Asked by**: Spec author (landscape-review adoption directive)
**Context**: Not every model benefits from an EPP (single-replica models see no gain; the EPP pod costs cpu/mem). Enabling must be per-claim and composition-owned, consistent with SPEC-002's composition-owned-routing philosophy.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `spec.gateway.endpointPicker.enabled` (default false), requires `gateway.enabled` via CEL | Nests under the routing block it modifies; opt-in; one field; consistent with `gateway`/`route`/`preload` style | Slightly deeper path |
| B | Top-level `spec.endpointPicker.enabled` | Flatter | Divorced from the gateway routing it only makes sense within; needs its own gateway-enabled CEL anyway |
| C | Always-on when `gateway.enabled` | No new field | Forces the EPP pod cost on single-replica models with no benefit; no gradual adoption |

**Decision**: A — `spec.gateway.endpointPicker.enabled`, default false, requiring `gateway.enabled` (CEL).
**Rationale**: EPP only alters gateway routing, so it belongs inside the SPEC-002 `gateway` block; opt-in mirrors the platform's progressive-complexity convention and lets a single model (`xplane-qwen-coder`) prove the wiring before any fleet rollout. FR-002.
**Decided by**: User (landscape-review adoption directive, 2026-07-12)
**References**: SPEC-002 `gateway` block; constitution §2 (composition patterns)

## CL-2 — 2026-07-12 — How is the EPP deployed — HelmRelease vs raw manifests, and which OCIRepository?

**Asked by**: Spec author
**Context**: The GAIE `inferencepool` chart v1.5.0 renders the InferencePool CR **and** the EPP Deployment/Service in one shot (verified: `inferenceextension.yaml` includes the `inference-extension.deployment`/`.service` helpers; `inferencepool.yaml` renders `kind: InferencePool`). The chart is already sourced at `flux/sources/ocirepo-inferencepool.yaml` as an `OCIRepository` named `inferencepool` in the **`llm`** namespace, but instantiated nowhere. A per-claim HelmRelease needs a chart source; Flux `chartRef` cross-namespace is allowed unless `--no-cross-namespace-refs` is set (verified NOT set on this cluster), but per-claim OCIRepositories rendered with a shared name would collide.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Per-claim `HelmRelease` referencing the shared static `llm`/`inferencepool` OCIRepository via `chartRef` (same-namespace) | Chart owns EPP+InferencePool+RBAC; HelmRelease GC'd with the claim; source is a single shared static object (no collision); same-namespace so cross-ns setting is moot | HelmRelease-per-claim (fine — matches App composition's kvStore HelmRelease pattern) |
| B | Per-claim `HelmRelease` + per-claim `OCIRepository` | Fully self-contained per claim | Two claims render the same OCIRepository name → conflict; per-claim source is needless churn; adds an `ocirepositories` RBAC grant |
| C | Composition renders raw InferencePool CR + EPP Deployment/Service/RBAC directly (no Helm) | No Flux dependency at render | Reimplements the chart's EPP wiring + pod-watch RBAC + library helpers; drifts from upstream on every v1.x bump; larger KCL surface |

**Decision**: A — per-claim `HelmRelease` `<name>-epp` referencing the **shared static `llm`-namespace `inferencepool` OCIRepository** (`flux/sources/ocirepo-inferencepool.yaml`, already present) via same-namespace `chartRef`. No per-claim OCIRepository; no `ocirepositories` RBAC grant needed.
**Rationale**: The chart is the upstream-blessed way to get EPP + InferencePool + its namespace-scoped pod-watch RBAC together; letting Crossplane own the HelmRelease gives clean GC-on-delete; reusing the existing shared source avoids name collisions and keeps the `additional-rbac.yaml` delta to a single `inferencepools` grant. `helmreleases` is already granted (App composition block). Same-namespace `chartRef` sidesteps the cross-namespace-refs question entirely. FR-001, FR-009.
**Decided by**: User (adoption directive) + verified chart/Flux behaviour, 2026-07-12
**References**: `flux/sources/ocirepo-inferencepool.yaml`; chart values <https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/config/charts/inferencepool/values.yaml>; Flux HelmRelease `chartRef` cross-namespace docs <https://fluxcd.io/flux/components/helm/helmreleases/>; `additional-rbac.yaml` (helmreleases already granted)

## CL-3 — 2026-07-12 — How does the AIGatewayRoute integrate the InferencePool?

**Asked by**: Spec author
**Context**: SPEC-002 renders the base rule `x-ai-eg-model: <claim>` → `AIServiceBackend → Backend → <claim> Service`. With an EPP, the base rule must instead hand the request to the InferencePool so the EPP picks the endpoint. Needed to verify how Envoy AI Gateway v1.0 composes AIGatewayRoute with an InferencePool.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Base rule `backendRefs → [{group: inference.networking.k8s.io, kind: InferencePool, name: <claim>}]` when endpointPicker on; pin rules + latch unchanged | Verified-supported by the AIGatewayRoute+InferencePool guide; minimal change to the SPEC-002 rule builder | Base rule loses `weight`/`modelNameOverride` (see CL-4) |
| B | Keep the AIServiceBackend chain and put the EPP in front of the Service | Not how the extension composes | Not supported; EPP is selected via the InferencePool backendRef, not a Service front |
| C | HTTPRoute + InferencePool (bypass AIGatewayRoute) | Simpler CRD | Loses AI Gateway model-header matching, token accounting, and the SPEC-002 routing model |

**Decision**: A — when `endpointPicker.enabled`, the base rule's `backendRefs` is a single InferencePool ref (`group: inference.networking.k8s.io`, `kind: InferencePool`, `name: <claim>`); the per-`loraAdapters[]` pin rules and the SPEC-002 readiness latch (FR-006) are unchanged.
**Rationale**: The Envoy AI Gateway AIGatewayRoute+InferencePool guide shows exactly this backendRef shape (`group: inference.networking.k8s.io`, `kind: InferencePool`, `name`). The latch stays because route existence must still gate on Deployment readiness regardless of the backend type. FR-004, FR-006.
**Decided by**: User + verified vendor doc, 2026-07-12
**References**: <https://aigateway.envoyproxy.io/docs/capabilities/inference/aigatewayroute-inferencepool/> (backendRef fields); <https://aigateway.envoyproxy.io/blog/endpoint-picker-for-inference-routing/>

## CL-4 — 2026-07-12 — Can weighted LoRA canary coexist with InferencePool routing on one rule?

**Asked by**: Spec author (verification of the SPEC-002 canary interplay)
**Context**: SPEC-002 canaries put multiple weighted `backendRefs` (with `modelNameOverride`) on the base rule. An InferencePool backendRef is a different kind. Needed to verify whether the two compose on the same rule.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Mutually exclusive per claim (CEL guard); InferencePool routing OR AIServiceBackend canaries, never both | Matches upstream reality; keeps both features clean; canary claims unaffected | A model can't do prefix-cache routing AND a LoRA canary at once (acceptable — different maturity phases) |
| B | Weighted mix of InferencePool + canary AIServiceBackends on one rule | Would be the richest routing | Upstream: an InferencePool backendRef supports neither `weight` nor `modelNameOverride`, and sources indicate one InferencePool per rule; not achievable in v1.5.0 |
| C | Canary through the InferencePool itself | Single mechanism | InferencePool has no weighted-adapter split concept; out of scope |

**Decision**: A — `endpointPicker.enabled` and any `gateway.canaries[]` entry are mutually exclusive, enforced by an XRD CEL guard. Canary claims keep the SPEC-002 AIServiceBackend routing; endpointPicker claims get InferencePool routing on the base rule (LoRA **pin** rules still work, since they route to the Service via AIServiceBackend, unaffected by the base-rule backend type).
**Rationale**: Verified that an InferencePool backendRef carries no `weight`/`modelNameOverride` (the AIGatewayRoute+InferencePool guide shows only `group`/`kind`/`name`), so a weighted base-rule split through an InferencePool is impossible in v1.5.0. A CEL guard is the cheapest, clearest way to prevent a silently-broken config. The follow-up seam: if upstream adds weighted InferencePool backendRefs, drop the guard. FR-005.
**Decided by**: User + verified vendor doc, 2026-07-12
**References**: <https://aigateway.envoyproxy.io/docs/capabilities/inference/aigatewayroute-inferencepool/>; SPEC-002 FR-003/FR-004 (canary weighting via AIServiceBackend + `modelNameOverride`)

## CL-5 — 2026-07-12 — Does each InferencePool/EPP select only its own claim's replicas?

**Asked by**: Spec author
**Context**: An InferencePool selects model-server pods via `modelServers.matchLabels`. The EPP then picks among the selected pods. Scoping determines whether an EPP can route across models.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Per-model pool selecting only the claim's pods (`app.kubernetes.io/name: <claim>`) | Correct semantics — EPP scores replicas of the same model; LoRA-awareness stays coherent; matches per-claim GC | One EPP pod per enabled model (cost — acceptable, opt-in) |
| B | One shared pool selecting all vLLM pods | Fewer EPP pods | EPP would route a request for model A to a pod serving model B; nonsensical; breaks prefix/LoRA scoring |

**Decision**: A — each rendered InferencePool sets `modelServers.matchLabels: {app.kubernetes.io/name: <claim>}` (the label vLLM pods already carry), selecting only that claim's replicas. Never cross-model.
**Rationale**: The whole value of EPP scoring (prefix-cache affinity, KV-cache utilization, LoRA presence) is only meaningful among replicas of the **same** model; cross-model selection is incorrect, not just wasteful. FR-003.
**Decided by**: User (adoption directive), 2026-07-12
**References**: chart `inferencePool.modelServers.matchLabels` (verified REQUIRED value); `main.k` vLLM pod labels `app.kubernetes.io/name: <claim>`

## CL-6 — 2026-07-12 — CiliumNetworkPolicy surface for the EPP pod

**Asked by**: Security owner (constitution §3.1 default-deny mandate — feature ADDS a pod)
**Context**: The EPP is a new pod on the inference data path. It watches Pods + InferencePool (kube-apiserver), scrapes vLLM `/metrics` (`:8000`), resolves DNS, and receives ext-proc calls from the Envoy data plane (`:9002`). Constitution requires a default-deny CNP for every pod-running workload; the `.claude/rules/cilium-network-policies.md` traps apply.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | New `<name>-epp` CNP (default-deny + explicit allow) + extend the claim's serving CNP to allow EPP `:8000` ingress | Constitution-compliant; scoped exactly to EPP's flows; reuses the SPEC-002 Envoy-data-plane selector | Two CNP touchpoints (new + serving extension) |
| B | Widen the serving CNP only | Fewer objects | The EPP pod itself would have no egress policy — violates default-deny for the new pod |
| C | No CNP (rely on namespace default) | Least work | Violates constitution §3.1 |

**Decision**: A. New EPP CNP: egress → claim vLLM pods `:8000` (`toEndpoints` on `app.kubernetes.io/name: <claim>`), kube-apiserver (`toEntities: ["kube-apiserver"]` — EPP watches Pods+InferencePool), kube-dns `:53` UDP/TCP **with `rules.dns.matchPattern: "*"`** (trap #1); ingress → Envoy data-plane pods on `:9002` (reuse the SPEC-002 `envoy-gateway-system`/`gateway.envoyproxy.io/owning-gateway-*` selector). Serving CNP `_metricsIngress`/`_defaultIngress` extended to allow EPP-pod ingress on `:8000`.
**Rationale**: Default-deny is non-negotiable for a new pod; the exact allow-list is small and known. The DNS `rules.dns` inclusion is mandatory or the EPP's outbound resolution silently drops (cilium-network-policies.md trap #1). kube-apiserver as `toEntities` (not toCIDR) is the correct Cilium idiom for the API server. The serving-CNP extension is required because the EPP scrapes vLLM `/metrics`, which the serving CNP would otherwise drop. FR-007. The precise apiserver-watch surface is confirmed on-cluster via Hubble in T010 (SC-005).
**Decided by**: Security owner + `.claude/rules/cilium-network-policies.md`, 2026-07-12
**References**: `.claude/rules/cilium-network-policies.md` (DNS L7 trap #1, host/entity trap #3); `main.k` `_metricsIngress`/`_defaultIngress`/`_dnsEgress`; constitution §3.1

## CL-7 — 2026-07-12 — How is PSS=restricted enforced on the EPP pod when the chart exposes no securityContext value?

**Asked by**: Security owner
**Context**: The `llm` namespace is PSS=restricted. The GAIE v1.5.0 `inferencepool` chart's `values.yaml` exposes **no** `securityContext`/`podSecurityContext` key for the EPP (verified — the EPP Deployment is rendered by the shared `inference-extension.deployment` library helper, not from chart values). If the upstream image's baked-in context isn't restricted-compliant, admission to `llm` will fail with the classic `must set securityContext.seccompProfile.type to "RuntimeDefault"` symptom, and there's no Helm value to plumb it through. This is the [NEEDS CLARIFICATION] in spec.md.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Assume the upstream EPP image is already restricted-compliant; verify on-cluster admission in T010, add a fallback only if it fails | GAIE targets restricted clusters (GKE Autopilot support), so likely compliant; smallest change | Unverified until the feature-branch deploy |
| B | Add a namespace-scoped Kyverno **mutate** policy that injects the restricted securityContext into EPP pods | Deterministic; platform already runs Kyverno; no dependency on chart internals | New policy object; must scope narrowly to EPP pods to avoid mutating unrelated workloads |
| C | Fork/override the chart to expose securityContext | Full control | Maintenance burden; drifts from upstream; defeats CL-2's "use the chart" rationale |

**Decision**: A as the primary path, B as the pre-authored fallback. Deploy on the feature-branch cluster and check EPP-pod admission (T010 / SC-005). If admission fails on securityContext, land a narrowly-scoped Kyverno mutate policy (Option B) selecting the EPP pod labels in the `llm` namespace, injecting `runAsNonRoot`, `allowPrivilegeEscalation: false`, `seccompProfile.type: RuntimeDefault`, `capabilities.drop: [ALL]` (and `readOnlyRootFilesystem` if the EPP tolerates it). Do NOT fork the chart.
**Rationale**: The chart genuinely offers no securityContext value, so the constitution's "plumb securityContext through chart values" rule (spec-constitution.md) cannot apply — the honest options are trust-and-verify or a Kyverno mutate. GAIE explicitly supports restricted environments, so Option A is likely sufficient; Kyverno is the platform's existing admission-mutation tool, making B a low-cost, in-pattern fallback. Forking (C) contradicts CL-2. The conservative posture is to verify before claiming compliance (process.md evidence gate). FR-008.
**Decided by**: Security owner + verified chart internals, 2026-07-12
**References**: chart `inferenceextension.yaml` (EPP via `inference-extension.deployment` helper — no securityContext value); `.claude/rules/spec-constitution.md` (Upstream Helm chart values plumbing; seccompProfile trap); constitution §3.3

## CL-8 — 2026-07-12 — How are the EPP's own metrics collected?

**Asked by**: SRE (constitution §5.1 — metrics to VictoriaMetrics)
**Context**: The EPP exposes Prometheus metrics (scheduler latency, picker decisions). The chart has a `monitoring.prometheus` ServiceMonitor path (default disabled). The platform standard is VictoriaMetrics `VMServiceScrape`, matching how the composition already scrapes vLLM.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Composition renders a `VMServiceScrape` `<name>-epp` selecting the EPP Service | Matches the existing vLLM `VMServiceScrape` pattern; VM-native; composition-owned + GC'd | Composition must know the EPP Service labels/port |
| B | Enable the chart's `monitoring.prometheus.enabled: true` ServiceMonitor | Chart-owned | Emits a Prometheus `ServiceMonitor`, not a VM `VMServiceScrape`; VM operator can consume ServiceMonitors but the repo standard is VMServiceScrape; chart's auth-token wiring adds complexity |
| C | No EPP scrape | Least work | Violates constitution §5.1; SC-006 needs EPP metrics; blind to picker health |

**Decision**: A — the composition renders a `VMServiceScrape` `<name>-epp` selecting the EPP Service (chart-labelled), scraping its metrics port. Keep the chart's own ServiceMonitor path disabled.
**Rationale**: Consistent with the composition's existing vLLM `VMServiceScrape` (main.k) and the constitution's VictoriaMetrics standard; composition-owned means it's GC'd with the claim and needs no separate lifecycle. SC-006 depends on EPP metrics being scraped. FR-010.
**Decided by**: SRE + constitution §5.1, 2026-07-12
**References**: chart `inferenceExtension.monitoring` values; `main.k` `_vmServiceScrape`; constitution §5.1; `.claude/rules/observability.md`

## CL-9 — 2026-07-12 — The EPP `/metrics` endpoint is authenticated by default

**Asked by**: PR #1559 review (2026-07-12)
**Context**: CL-8 chose a composition-owned `VMServiceScrape` and deliberately left the chart's own ServiceMonitor path disabled. What CL-8 missed: the chart value that gates the ServiceMonitor is **not** the only thing `monitoring.prometheus.*` controls. `inferenceExtension.monitoring.prometheus.auth.enabled` defaults to **true**, and epplib's deployment template passes `--metrics-endpoint-auth=false` **only when that value is false**. Left at the default, the EPP enforces bearer-token authn on `:9090/metrics` and 401s our credential-less `VMServiceScrape` — the scrape is rendered, healthy-looking, and returns nothing. Separately, the EPP's own default-deny CiliumNetworkPolicy had no allow for the metrics port, so the scrape was being DROPPED before it could even 401.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Set `inferenceExtension.monitoring.prometheus.auth.enabled: false`; let the EPP CNP be the access control (only vmagent may reach `:9090`) | One value; no token plumbing; the CNP already scopes the port to a single peer; consistent with how every other scrape in the repo works | Metrics endpoint is unauthenticated *within* the allowed peer set |
| B | Keep auth on; add `authorization.credentials` to the `VMServiceScrape` pointing at the chart's SA-token Secret | Defence in depth | The chart only creates that Secret when `monitoring.prometheus.enabled: true`, which also emits a ServiceMonitor we explicitly do not want (CL-8); vmagent then needs cross-namespace Secret read; two mechanisms guarding one port |
| C | Leave as-is | — | The EPP scrape simply does not work; SC-006 unmeasurable |

**Decision**: A — disable the EPP's metrics-endpoint auth filter, and add the missing vmagent→`:9090` ingress rule to the EPP CiliumNetworkPolicy.
**Rationale**: The port is not reachable by anything except vmagent (default-deny + one explicit allow), so the token adds a second lock on a door only one process can reach — at the cost of dragging in the chart's ServiceMonitor and a cross-namespace Secret. Network policy is the access control the platform already relies on for every other metrics port, including vLLM's. The CNP allow is the load-bearing half: without it the scrape is DROPPED silently, which is precisely trap #1 in `.claude/rules/cilium-network-policies.md`.
**Decided by**: PR #1559 review, verified against the v1.5.0 chart
**References**: `kubernetes-sigs/gateway-api-inference-extension` v1.5.0 `config/charts/inferencepool/values.yaml` (`monitoring.prometheus.auth.enabled: true`), `config/charts/epplib/templates/_deployment.yaml` (`{{- if not ...auth.enabled }} - --metrics-endpoint-auth=false`), `_servicemonitor.yaml`, `_sa-token-secret.yaml`; `main.k` `_eppIngressRules` / `_metricsIngress`; CL-8  <!-- pragma: allowlist secret -->

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
