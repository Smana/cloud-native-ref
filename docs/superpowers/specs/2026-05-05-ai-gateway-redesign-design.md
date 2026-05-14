# AI Gateway Redesign — Envoy AI Gateway + InferencePool + EPP

**Status:** Implemented offline (P1–P5 manifests committed, smoke verification gated on cluster bring-up). The legacy CEC + `llm-router-proxy` safety-net was dropped in the same PR per a reframed design call (solo experimental scope, blog-post-honesty wins over rollback insurance) — so P5 is no longer a deferred phase, just the "removed-in-this-PR" set.
**Date:** 2026-05-05
**Branch:** `wip/self-hosted-llm-platform-draft`
**Supersedes:** `2026-05-05-llm-router-proxy-design.md` and `-plan.md` (custom Go proxy + GHCR workflow)
**Related tasks:** #76 (composition CNP cleanup), #78 (ext_proc cold-connect), #108–112 (llm-router-proxy work — obsoleted)

---

## 1. Goal & Success Criteria

**Goal.** Replace the current routing stack (CEC on cilium-envoy + ext_proc body callback + the custom Go `llm-router-proxy`) with **Envoy AI Gateway + InferencePool + EPP**, on a **dedicated Envoy data plane** (not cilium-envoy), so that:

1. Header-match routes between models work (no L7 policy interference).
2. SR (vllm-semantic-router) drives routing via ext_proc; the previous `clearRouteCache=false` problem is structurally removed via filter ordering (SR runs *before* the body parser).
3. Per-model routing uses `InferencePool` CRDs with **EPP (Endpoint Picker Plugin)** doing vLLM-aware endpoint selection — the modern gateway-api-inference-extension shape.
4. The custom Go proxy is **deleted** along with its image, GHCR workflow, and CEC.

**Non-goals.** Multi-region, on-prem expansion, cost-based routing, request batching/queuing at the gateway, replacing OpenWebUI as the chat surface.

**Context.** The platform serves a **solo experimental** workload (1 user, IDE-driven coding agent + occasional chat) but the architecture is intentionally **evolutive** — the same wiring scales to multi-replica without migration. The platform also serves as the subject of a **whole-stack blog post** demonstrating the modern cloud-native LLM serving pattern. The blog post must honestly distinguish "wiring that scales" from "wiring that is currently scaled" — at N=1 today, EPP's endpoint picker is effectively a no-op, but the same topology delivers least-loaded selection at N>1.

### Success Criteria

| ID | Criterion | Evidence |
|----|-----------|----------|
| SC-01 | Request with `model:"MoM"` is classified by SR and routed to the recommended model | `curl /v1/chat/completions` with MoM → response carries `x-vsr-selected-model` header matching the recommended model; vLLM logs on that pod show the request |
| SC-02 | Request with explicit `model:"qwen3-8b"` skips classification and routes directly | SR ext_proc shows zero classify calls; qwen3-8b vLLM pod receives it |
| SC-03 | Header-match routing works on the dedicated Envoy (no `403 Access denied`) | Hubble + Envoy access logs show `:status 200` end-to-end for all 5 models |
| SC-04 | InferencePool's EPP correctly reports a single-endpoint pool today; the wiring delivers least-loaded selection once any model scales to N>1 | EPP pod logs show endpoint scoring; at N=1 the only pod is selected; at N>1 (manually scaled smoke test) requests fan out across replicas |
| SC-05 | Custom `llm-router-proxy` is removed | `tooling/llm-router-proxy/` directory does not exist; GHCR workflow file deleted; no manifests reference its image; GHCR package deleted |
| SC-06 | All new pods comply with restricted PSS | `kubectl get pods -n llm -o yaml` shows seccompProfile + non-root + no privilege-escalation across new components (Envoy data plane, EPP, AI Gateway controller) |
| SC-07 | Cilium default-deny is preserved | New CNPs cover every new workload; `hubble observe --verdict DROPPED` shows no expected-traffic drops |

---

## 1.1. Routing-pattern choice (verified against upstream)

The gateway-api-inference-extension docs ([upstream](https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/main/site-src/guides/serve-multiple-genai-models.md)) and Envoy AI Gateway docs ([upstream](https://github.com/envoyproxy/ai-gateway/blob/main/site/blog/2025/2025-07-30-epp-introduction.md)) both document **two valid patterns** for multi-model routing on top of `InferencePool`:

| Pattern | Resource | Header set by | Upstream framing |
|---------|----------|---------------|------------------|
| **HTTPRoute + BBR** | vanilla `HTTPRoute` (`gateway.networking.k8s.io/v1`) | Body-Based Routing ext_proc copies `body.model` → `X-Gateway-Model-Name` | "Simple inference workloads with basic intelligent routing" |
| **AIGatewayRoute** | `AIGatewayRoute` (`aigateway.envoyproxy.io/v1beta1`) | AI Gateway's built-in body parser sets `x-ai-eg-model` | "Advanced AI-specific routing with token rate limiting + schema translation" |

**We chose AIGatewayRoute → InferencePool.** Rationale:

1. **Built-in body parser** — no separate BBR ext_proc component to deploy. AI Gateway's controller manages it as part of the same chart.
2. **Future-proof for token rate limiting** — `llmRequestCosts` (`InputToken`, `OutputToken`, `TotalToken`) is a first-class CRD field on `AIGatewayRoute`. We don't need it today (solo experimental), but the moment we share access with colleagues or open the chat surface, we want per-user/per-model token quotas.
3. **Schema-translation optionality** — if we ever proxy to a hosted Anthropic/Bedrock model from the same gateway, AI Gateway's `schema:` field handles the OpenAI→provider format conversion at zero additional engineering cost.
4. **Blog-post fidelity** — the post is about the *modern* AI gateway stack. `AIGatewayRoute` IS the AI-aware layer; HTTPRoute+BBR is the same primitive minus the AI-specific affordances.

**Cost we accept:** one extra controller (Envoy AI Gateway) on top of Envoy Gateway, two CRD groups (`gateway.envoyproxy.io` + `aigateway.envoyproxy.io`). Acceptable for the demo + solo lab.

If the AI-specific features ever turn out to be unused for >6 months and the maintenance cost exceeds the optionality value, **the migration to HTTPRoute+BBR is mechanical**: replace `AIGatewayRoute` → `HTTPRoute`, header name `x-ai-eg-model` → `X-Gateway-Model-Name`, deploy BBR via the gateway-api-inference-extension chart. `InferencePool` and EPP layers are unchanged. Both upstream sources publish recipes for both shapes.

### Verified upstream schema details (chart v1.0.0)

The `inferencepool` v1.0.0 Helm chart (rendered locally with `helm template`) emits:

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
spec:
  targetPorts:
    - number: 8000
  selector:
    matchLabels:
      <chart parameter>
  endpointPickerRef:        # NOT extensionRef (older v1alpha2 docs are stale)
    name: <pool>-epp
    port:
      number: 9002
```

The EPP pods carry a `inferencepool: <pool>-epp` pod-template label (chart-rendered) — the basis for the `_defaultIngress` `matchExpressions` rule in the InferenceService composition (§4).

---

## 2. Architecture Overview

### Data flow

```
                  Tailscale gateway (existing)
                           │
                           ▼
                ┌────────────────────────┐
                │  Envoy AI Gateway      │  ← dedicated Envoy pod
                │  data plane            │     (NOT cilium-envoy)
                │                        │
                │  filter chain:         │
                │   1. ext_proc → SR     │  ← classify-then-rewrite
                │   2. ai_gateway parser │  ← reads (mutated) body.model
                │                          → sets x-ai-eg-model header
                │   3. router            │  ← matches AIGatewayRoute
                │                          on x-ai-eg-model
                └────────┬───────────────┘
                         │ (chosen InferencePool)
                         ▼
              ┌──────────────────────────────┐
              │ inference-extension          │  ← cluster-phase ext_proc
              │ endpoint picker (EPP gRPC)   │
              │  • scores pod IPs from       │
              │    /metrics (queue depth,    │
              │    KV-cache, model)          │
              │  • returns chosen pod IP     │
              └────────┬─────────────────────┘
                       ▼
              ┌──────────────────┐
              │ vLLM pods        │  ← per-model deployments
              │ qwen3-8b,        │     (unchanged from today)
              │ qwen-coder,      │
              │ qwen-coder-fim,  │
              │ phi4-mini,       │
              │ llamaguard3-1b   │
              └──────────────────┘
```

### Components

| Component | Role | New / Reused / Removed |
|-----------|------|------------------------|
| **Envoy AI Gateway controller** | Translates `AIGatewayRoute` / `AIServiceBackend` CRDs into Envoy config; owns the dedicated data-plane Deployment | **NEW** — `infrastructure/base/envoy-ai-gateway/` |
| **Envoy AI Gateway data plane** | The actual proxy pod(s); spawned by controller | **NEW** |
| **vllm-semantic-router (SR)** | Receives ext_proc bidi stream; classifies on `model:"MoM"` or `"auto"`; mutates body's `model` to `recommended_model`; queues response-header mutation `x-vsr-selected-model` | **REUSED** — `infrastructure/base/vllm-semantic-router/` |
| **InferencePool (1 per model)** | gateway-api-inference-extension CRD; declares the model + selector for vLLM pods + extensionRef → EPP | **NEW** — emitted by the InferenceService Crossplane composition |
| **EPP — Endpoint Picker Plugin (1 Deployment per pool)** | Talks to vLLM `/metrics` (queue depth, KV-cache); scores endpoints; serves ext_proc to the gateway data plane | **NEW** — emitted by the composition |
| **vLLM pods** | Inference workers, 1 Deployment per model | **REUSED** |
| **Crossplane `InferenceService` composition (KCL)** | Today renders Deployment + Service + ServiceMonitor per claim | **MODIFIED** — drop the per-claim `xplane-<model>` Service; emit InferencePool + EPP Deployment + EPP Service instead |
| **CiliumEnvoyConfig** (`infrastructure/base/llm-ai-gateway/cec.yaml`) | Today: tries header-match on cilium-envoy | **REMOVED** entirely |
| **`llm-router-proxy`** (`tooling/llm-router-proxy/`) | Today: stop-gap Go proxy doing classify+rewrite | **REMOVED** — code, Dockerfile, GHCR workflow, image |
| **Tailscale Gateway** | External entry | **REUSED** — its HTTPRoute backendRefs are repointed from `xplane-llm-ai-gateway` → the AI Gateway data plane Service |

### Networking & policy boundaries

New CiliumNetworkPolicies (default-deny + explicit allow):

| Source → Destination | Port/Proto | CNP location |
|----------------------|------------|--------------|
| Tailscale Gateway → AI Gateway data plane | TCP 8080 (HTTP) | `infrastructure/base/envoy-ai-gateway/network-policy.yaml` |
| AI Gateway data plane → SR ext_proc | TCP 50051 (gRPC) | `infrastructure/base/vllm-semantic-router/network-policy.yaml` (extend existing) |
| AI Gateway data plane → EPP ext_proc | TCP 9002 (gRPC) | per-claim CNP from composition (or composition-level CNP scoping) |
| AI Gateway data plane → vLLM pods (chosen by EPP) | TCP 8000 (HTTP) | per-claim CNP from composition |
| EPP → vLLM pods | TCP 8000 (HTTP `/metrics`) | per-claim CNP from composition |
| AI Gateway controller → Kubernetes API | TCP 443 | controller CNP |
| Default-deny | * | every workload |

---

## 3. Data flow & the `clearRouteCache` mechanism

**Key insight.** In the previous (broken) CEC architecture, SR ran *after* the route was selected, so SR's body mutation had no routing effect — and SR v0.2.0 hardcodes `clearRouteCache=false` in `buildRequestBodyContinueResponse`, blocking the obvious fix.

In the new architecture, **filter ordering inverts the dependency**: SR's ext_proc runs *before* Envoy AI Gateway's body parser. By the time the gateway extracts the `model` field, it has already been rewritten. **`clearRouteCache` is structurally unreachable as a problem.**

### Filter chain (request path)

```
HTTP Connection Manager
  │
  ├─ envoy.filters.http.ext_proc       ← SR (vllm-semantic-router)
  │     • body mode: BUFFERED
  │     • behavior:
  │         if body.model in {"MoM", "auto"}:
  │           classify(last_user_text) → recommended_model
  │           mutate body.model = recommended_model
  │           queue response_header_mutation: x-vsr-selected-model = recommended_model
  │         else: pass-through (no body mutation, no header)
  │
  ├─ envoy.filters.http.ai_gateway     ← AI Gateway built-in body parser
  │     • reads body.model (now rewritten)
  │     • sets request header: x-ai-eg-model = body.model
  │
  ├─ envoy.filters.http.router         ← matches AIGatewayRoute on
  │                                       header x-ai-eg-model
  ▼
Route → AIServiceBackend (kind: InferencePool, name: qwen3-8b-pool)
  │
  ▼
Cluster (Envoy upstream)
  │
  ├─ inference-extension endpoint picker  ← second ext_proc (cluster-phase)
  │     • talks to EPP gRPC
  │     • EPP scores pod IPs by /metrics
  │     • returns chosen pod IP
  │
  ▼
vLLM pod (e.g., qwen3-8b-0)
```

### Walk-through: a "MoM" request

1. **Client** → `POST /v1/chat/completions` body `{"model":"MoM","messages":[...]}`
2. **SR ext_proc** (filter 1): classifies last user text → `qwen3-8b`, mutates body's `model`, queues `x-vsr-selected-model: qwen3-8b` for the response.
3. **AI Gateway body parser** (filter 2): sees mutated body, sets request header `x-ai-eg-model: qwen3-8b`.
4. **Router** (filter 3): matches `AIGatewayRoute` rule `headers: [x-ai-eg-model=qwen3-8b]` → backend is `InferencePool/qwen3-8b-pool`.
5. **EPP ext_proc** (cluster-phase): scores pool's pod IPs, returns one. At N=1, returns the only pod. At N>1, returns the least-loaded one.
6. **vLLM pod** receives the request with `model: qwen3-8b` (so the OpenAI-compat server doesn't reject it) and streams the response.
7. **SR's queued response-header mutation** is applied as the response goes out — client sees `x-vsr-selected-model: qwen3-8b`.

### Walk-through: an explicit-model request

1. **Client** → `POST /v1/chat/completions` body `{"model":"qwen-coder","messages":[...]}`
2. **SR ext_proc**: `model` is not `MoM` or `auto` → pass-through, zero classify call.
3–7. Same path: parser sees `qwen-coder` → header → route → InferencePool/qwen-coder-pool → EPP picks pod → vLLM. Response header `x-vsr-selected-model` is **absent** (SR didn't set one) — explicit models don't carry the SR badge.

### Implementation gate (Phase 2)

The above assumes Envoy AI Gateway lets us inject SR's ext_proc *before* its built-in body parser via `EnvoyExtensionPolicy` with `targetRef → AIGatewayRoute`. This is documented but not the most-trodden path. **We verify with a single-route smoke test in Phase 2.** If the ordering can't be enforced, fallback is the Lua + clearRouteCache approach: place SR after the parser, then `request_handle:clearRouteCache()` in a Lua filter (~10 lines).

The dedicated Envoy data plane is a standard Envoy build (not cilium-envoy's slim variant), so the Lua filter **is available** — that's a key reason for the dedicated data plane.

### Why this is structurally better than the CEC attempt

| Constraint that broke CEC | How new architecture handles it |
|----------------------------|----------------------------------|
| cilium-envoy lacks `envoy.filters.http.lua` | Dedicated Envoy data plane has the standard filter set |
| `cilium.l7policy` filter denies header-match routes | Dedicated Envoy doesn't run cilium.l7policy (that's a cilium-envoy injection) |
| SR v0.2 hardcodes `clearRouteCache=false` | Filter ordering removes the dependency on clearRouteCache entirely |
| ext_proc gRPC stream cold-connect drops first request (#78) | Tightened HTTP/2 keepalive (task #91, shipped) + AI Gateway's longer-lived control connections reduce surface; revisit if reproduces |

---

## 4. KCL composition & manifest changes

### Crossplane `InferenceService` composition

Location: `infrastructure/base/crossplane/configuration/kcl/inference-service/`

Per-claim resources rendered:

| Resource | Today | After |
|----------|-------|-------|
| vLLM `Deployment` | ✅ | ✅ unchanged |
| `Service` (`xplane-<model>`) | ✅ | ❌ **removed** — replaced by InferencePool selection |
| `ServiceMonitor` / `VMServiceScrape` | ✅ (targets the Service) | ✅ converted to `PodMonitor` / `VMPodScrape` (or kept as a headless internal Service for direct-debug; final shape decided in P4 implementation) |
| `InferencePool` | ❌ | ✅ **new** — selector matches vLLM pod labels, targetPortNumber: 8000, extensionRef → EPP Service |
| EPP `Deployment` | ❌ | ✅ **new** — image `registry.k8s.io/gateway-api-inference-extension/epp:vX`, restricted PSS, per-pool isolation |
| EPP `Service` | ❌ | ✅ **new** — ClusterIP for the gateway data plane to reach EPP gRPC |
| Per-claim `CiliumNetworkPolicy` | ✅ (overrides per task #76) | ✅ but composition-level — task #76 overrides become unnecessary because InferencePool's selector + the gateway data-plane selector are the only allowed ingress, expressed once |

### New manifests

| Path | Purpose |
|------|---------|
| `infrastructure/base/envoy-ai-gateway/helmrelease.yaml` | Envoy AI Gateway controller HelmRelease |
| `infrastructure/base/envoy-ai-gateway/gateway.yaml` | The `Gateway` resource that spawns the dedicated Envoy data plane |
| `infrastructure/base/envoy-ai-gateway/network-policy.yaml` | CNP for controller + data plane |
| `infrastructure/base/envoy-ai-gateway/kustomization.yaml` | Kustomization wiring |
| `apps/base/ai/llm/ai-gateway-routes/<model>-route.yaml` | One `AIGatewayRoute` + `AIServiceBackend` per model (5 files) |
| `apps/base/ai/llm/ai-gateway-routes/kustomization.yaml` | Kustomization wiring |
| `infrastructure/base/vllm-semantic-router/extension-policy.yaml` | `EnvoyExtensionPolicy` that injects SR's ext_proc before the AI Gateway body parser |

### Removals (Phase 5)

| Path | Reason |
|------|--------|
| `infrastructure/base/llm-ai-gateway/cec.yaml` | CEC approach abandoned |
| `infrastructure/base/llm-ai-gateway/service.yaml` | Replaced by AI Gateway data-plane Service |
| `infrastructure/base/llm-ai-gateway/network-policy.yaml` | Subsumed by AI Gateway CNPs |
| `infrastructure/base/llm-ai-gateway/kustomization.yaml` | Directory deleted |
| `tooling/llm-router-proxy/` (entire directory) | Custom Go proxy obsoleted |
| `.github/workflows/llm-router-proxy.yml` | GHCR workflow obsoleted |

### Tailscale gateway redirect

Update the existing Tailscale `HTTPRoute` for `llm.priv.cloud.ogenki.io` (or equivalent host) to set `backendRefs` → the AI Gateway data-plane Service instead of `xplane-llm-ai-gateway`.

---

## 5. Phased rollout

Five phases. Each is independently mergeable. The `llm-router-proxy` is fully retained until Phase 5 — it's the safety net.

| Phase | Goal | Mergeable independently? |
|-------|------|--------------------------|
| **P1 — Smoke** | Deploy Envoy AI Gateway controller + a *single* `AIGatewayRoute` for `qwen3-8b` only. No SR ext_proc, no InferencePool — plain `AIServiceBackend → xplane-qwen3-8b Service`. Goal: prove the dedicated Envoy data plane handles a request and returns 200 (kills the cilium-envoy L7-policy concern definitively). | Yes |
| **P2 — SR wiring** | Add SR as an ext_proc filter ahead of the AI Gateway body parser via `EnvoyExtensionPolicy`. Verify filter ordering works (gate from §3). Smoke: `model:"MoM"` → classified → routed to qwen3-8b. If ordering doesn't work, drop in Lua fallback. | Yes |
| **P3 — Full fleet routing** | One `AIGatewayRoute` + `AIServiceBackend` per model (still Service-backed — no InferencePool yet). All 5 models routable by name; SR cascade decisions cover them. | Yes |
| **P4 — InferencePool + EPP** | Refactor the InferenceService KCL composition to emit InferencePool + EPP per claim. Switch each `AIServiceBackend` from `Service` → `InferencePool`. Drop the per-model `xplane-<model>` Services. Drop the per-claim CNP overrides (task #76). | Yes (per-model migration possible) |
| **P5 — Demolition** | Delete `infrastructure/base/llm-ai-gateway/`, `tooling/llm-router-proxy/`, the GHCR workflow, the old Tailscale HTTPRoute target. Update `clusters/mycluster-0-llm-platform/README.md`. Delete the GHCR package. Close tasks #76, #78, #108–112. | Yes (final phase) |

**Rollback at each phase:** `flux suspend kustomization <new-kustomization>` brings the cluster back to the prior phase. The `llm-router-proxy` deployment + its CEC stay running until P5 — clients can be cut over at the Tailscale HTTPRoute level (one-line change).

---

## 6. User-visible surface

**Unchanged contract on the wire:**
- `POST /v1/chat/completions`, `POST /v1/completions` — OpenAI-compatible.
- Virtual model `MoM` (or `auto`) triggers SR classification.
- Explicit model names (`qwen-coder`, `qwen-coder-fim`, `qwen3-8b`, `phi4-mini`, `llamaguard3-1b`) skip classification.
- Response header `x-vsr-selected-model` reports the chosen model when SR classified; absent for explicit-model requests.
- **Warm-target constraint:** today only `qwen-coder-fim`, `qwen-coder`, and `qwen3-8b` run with `min=1`. `phi4-mini` and `llamaguard3-1b` stay scale-to-zero, and KEDA's prometheus trigger can't scale them from zero (no pods → no metric → no signal). SR's `general_decision` cascade target was therefore remapped from `phi4-mini` to `qwen3-8b`; the user-facing API surface is unchanged. See `clusters/mycluster-0-llm-platform/README.md` for the always-warm rationale and the planned KEDA HTTP-queue-scaler unblocker.

**Changes:**
- New informational header: `x-ai-eg-backend` reports the InferencePool name (`qwen3-8b-pool` etc.) — useful for observability + blog post diagrams.
- Hostname unchanged (Tailscale-fronted, e.g., `llm.priv.cloud.ogenki.io`); only the underlying Service the Tailscale Gateway HTTPRoute points to changes.
- **OpenWebUI / OpenCode / Continue configs need zero changes** — the OpenAI-compat surface is the contract.

---

## 7. Risks & open items

### Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Filter ordering (`EnvoyExtensionPolicy` injecting SR before AI Gateway body parser) doesn't compose as expected | Medium | High — blocks P2 | Lua + clearRouteCache fallback (~10 lines); dedicated Envoy has Lua available |
| EPP version pinned to a CRD/API that shifts under us | Low | Medium | Pin to a known-good tag; gateway-api-inference-extension is v1alpha2 — expect churn; document the pin |
| Envoy AI Gateway controller CRDs conflict with existing Gateway API CRDs in the cluster | Low | High — cluster-wide | Verify CRD names + API groups before P1 deploy; AI Gateway uses `aigateway.envoyproxy.io` group, distinct from gateway.networking.k8s.io |
| InferencePool selector matches more pods than expected (e.g., across model claims) | Low | High — request mis-routing | Composition writes selectors keyed on the claim name; main_test.k validates label uniqueness |
| EPP scrape of vLLM `/metrics` requires cred / mTLS that vLLM doesn't expose | Low | Medium | vLLM's metrics endpoint is unauthenticated by default; if that changes, EPP supports HTTP basic auth + bearer token |
| Blog post implies multi-replica behavior that doesn't exist | Medium | Reputational | SC-04 explicitly distinguishes wiring vs. runtime behavior; blog post must include the N=1 caveat + a manual-scale demo for the EPP section |

### Open items (decided in implementation, not here)

- **PodMonitor vs. headless Service for vLLM scraping** — decided in P4 based on what VictoriaMetrics integration prefers.
- **Exact EPP image tag** — pin during P4; verify against gateway-api-inference-extension release notes.
- **Whether SR's response-header mutation survives the AI Gateway response path** — verify in P2 smoke; if AI Gateway strips unknown headers, add an explicit `responseHeadersToAdd` on the route.
- **EPP pods run with no `resources` requests/limits**. The upstream `inferencepool` v1.0.0 chart hardcodes the EPP container without a `resources` block and exposes no values knob to inject one. 5 BestEffort pods on a constrained cluster are first-to-evict under pressure and don't reserve scheduling capacity — minor violation of constitution §Security defaults. Fixes require either an upstream PR (preferred) or a Flux `postRenderers` Kustomize patch per HelmRelease (introduces a new pattern in this repo, deferred). Track upstream issue + revisit when chart exposes the knob.

---

## 8. Out-of-scope (deferred)

- Multi-replica autoscaling (KEDA HPA on vLLM Deployments) — separate spec when the GPU budget allows it.
- Cost-based or latency-based routing in SR — SR cascade decisions are signal-fusion-based today; cost routing is a future SR feature.
- Replacing OpenWebUI as the chat surface.
- gRPC API support — current contract is OpenAI HTTP-compat; gRPC would be a separate gateway listener.
- Federated multi-cluster gateway.

---

## 9. References

- **Envoy AI Gateway**: <https://aigateway.envoyproxy.io/> (controller + AIGatewayRoute / AIServiceBackend CRDs)
- **gateway-api-inference-extension** (InferencePool + EPP): <https://gateway-api-inference-extension.sigs.k8s.io/>
- **vllm-semantic-router** v0.2.0 source: hardcoded `clearRouteCache=false` in `buildRequestBodyContinueResponse` motivates filter ordering
- **Superseded specs:** `docs/superpowers/specs/2026-05-05-llm-router-proxy-design.md`, `-plan.md`
- **Related repo rules:** `.claude/rules/cilium-network-policies.md`, `.claude/rules/kcl-crossplane.md`, `.claude/rules/spec-constitution.md`
- **CLAUDE.md**: Self-Hosted LLM Platform section — opt-in gates (Terramate `TM_LLM_PLATFORM_ENABLED`, Flux umbrella suspend)

---

## 10. Implementation plan handoff

Next step: invoke the writing-plans skill (or the SDD `/spec` workflow) to produce a phased implementation plan with TDD-shaped tasks. Plan filename will mirror this design: `docs/superpowers/specs/2026-05-05-ai-gateway-redesign-plan.md`.

Tasks #108–112 (the remaining `llm-router-proxy` work) are **superseded** and should be marked as such in the task list with a pointer to this design.
