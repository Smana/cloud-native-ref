# Spec: vLLM autoscaling on production-realistic signals

**ID**: SPEC-001
**Issue**: TBD (folded into PR #1434 — wip/self-hosted-llm-platform-draft)
**Status**: done
**Type**: platform
**Created**: 2026-05-07
**Last updated**: 2026-05-07

> Replace the KEDA HTTP add-on (request-count proxy in the data path) with KEDA `prometheus`-trigger `ScaledObject`s using leading vLLM-internal saturation metrics. Removes the proxy hop, removes the timeout traps that surfaced repeatedly in PR #1434, and surfaces production-meaningful scaling behaviour for the POC demo.

---

## Summary

Drop the KEDA HTTP add-on from the LLM-platform data path. Scale each vLLM model on **leading** internal saturation metrics — concurrent batch fill (`vllm:num_requests_running` / `max-num-seqs` ratio) and KV-cache pressure (`vllm:gpu_cache_usage_perc`) — via KEDA `prometheus` triggers, with `minReplicas=1` for all 4 models. Routes simplify back to the standard AI Gateway pattern (AIServiceBackend → vLLM Service direct).

---

## Problem

The current scaling design (PR #1434, composition v0.4.0–v0.4.3) wires every scale-from-zero model through the KEDA HTTP add-on interceptor. Three distinct failure modes have surfaced during e2e validation, all rooted in the wrong primitive being used:

1. **The scale signal is wrong for inference.** Request count at the proxy doesn't reflect GPU saturation. One 32k-context request can fill 30–50% of KV cache; counting it as "1 request" hides the real load. By the time `num_requests_waiting > 0`, users are already waiting and pod-start (60–120s) is in front of them.
2. **The proxy hop adds operational surface for no inference benefit.** The interceptor's chart-default `responseHeaderTimeout: 500ms` truncated streaming responses (PR #1434, fixed by bumping to 30s); the Envoy auto-host-rewrite collided with `headerMutation.set Host` (PR #1434, fixed via plain HTTPRoute hack); the per-pod label CNP-allow rule was wrong (`name=interceptor` vs `component=interceptor`). Each fix landed; the underlying mismatch (HTTP-proxy semantics vs LLM serving semantics) didn't.
3. **`min=0` deadlock-by-default.** The original prometheus-triggered ScaledObject (composition v0.3.x) couldn't scale 0→1 because no pod = no metric = no signal. We migrated to HTTP add-on to solve that; but the user's clarified intent is *"in production we'd keep min=1 anyway"*, so the deadlock-driver of the migration no longer applies.

The desired outcome is a scaling design that is **production-realistic in its trigger criteria**, not optimised for the demoable cold-start-from-zero path.

---

## User Stories

### US-1: Operator scales LLM platform on real GPU saturation (Priority: P1)

As a **platform operator**, I want **autoscaling decisions driven by signals vLLM emits about its own saturation state** (running request count vs configured batch size, KV-cache utilisation), so that **a new replica is provisioned before users feel the previous one degrade**, not after.

**Acceptance Scenarios**:
1. **Given** a model at 1 replica with `max-num-seqs=64` and `num_requests_running=48` (75%), **When** sustained for `pollingInterval+activationDelay` (~30s), **Then** KEDA scales the deployment to 2 replicas before any request enters the formal `num_requests_waiting` queue.
2. **Given** a single 32k-context request fills `gpu_cache_usage_perc` to 65%, **When** that request is in flight, **Then** scaling is triggered (cache > 60% threshold) even though `num_requests_running=1`.
3. **Given** load drops to 0 sustained for `cooldownPeriod` (5min), **When** no other trigger fires, **Then** the model scales back to `minReplicas=1` (not 0).

### US-2: Demo viewer sees production-realistic scaling behaviour (Priority: P1)

As a **demo viewer**, I want to see **the kind of scaling behaviour I'd see in a production deployment**, so that **the architecture I'm being shown is one I could actually run, not a toy that hides operational complexity behind a proxy**.

**Acceptance Scenarios**:
1. **Given** the LLM platform is freshly deployed with all 4 models at `minReplicas=1`, **When** I send 8 concurrent `xplane-qwen-coder` requests via `curl --parallel`, **Then** within ~120s a second replica becomes Ready and load distributes across both.
2. **Given** the cluster is idle for > 10min, **When** I inspect the platform, **Then** all 4 models still have exactly 1 replica running (no scale-down to 0) — matching how it would run in production.

### US-3: Architecture passes "could you run this in prod?" review (Priority: P2)

As a **prospective adopter** reviewing the platform, I want **the data path to be Envoy → vLLM with no extra proxy**, so that **debugging latency, streaming SSE behaviour, and request tracing are all standard operations rather than dependencies on a third-party shim's chart defaults**.

**Acceptance Scenarios**:
1. **Given** I trace one request from Tailscale to vLLM completion logs, **When** I count L7 proxies in the data path, **Then** I count exactly one (Envoy AI Gateway).
2. **Given** I want to add a per-request feature (rate limiting, JWT auth, request-shadowing), **When** I configure it, **Then** I configure it on the AI Gateway only — there is no second proxy with its own configuration surface.

---

## Requirements

### Functional

- **FR-001**: System MUST scale vLLM model deployments based on **leading** vLLM internal metrics (`vllm:num_requests_running` / configured `max-num-seqs` ratio AND `vllm:gpu_cache_usage_perc`), not proxy request count.
- **FR-002**: System MUST default `minReplicas=1` for every vLLM `InferenceService`. The demo can override per-model to `0` for a one-off "scale-from-zero" showcase, but it is no longer the default.
- **FR-003**: System MUST route inference traffic from the AI Gateway directly to each vLLM Service via `AIServiceBackend` → `Backend(FQDN=xplane-<model>.llm.svc.cluster.local:8000)` — no KEDA HTTP interceptor in the data path.
- **FR-004**: KEDA `ScaledObject`s MUST poll metrics every `pollingInterval=15s` and respect `cooldownPeriod=300s` (5min — long enough to amortise vLLM CUDA-graph compile cost on scale-up, short enough to release idle GPU pods quickly).
- **FR-005**: The `inference-service` KCL composition MUST emit `ScaledObject` (not `HTTPScaledObject`) and configure both triggers per model. The composition MUST expose per-model `maxNumSeqs` (default 256) so the running-vs-batch ratio threshold is computed correctly.
- **FR-006**: Lagging signals (`num_requests_waiting > 0` for 60s sustained, `time_to_first_token_seconds` p95 > target) MUST surface as **VMRule alerts**, not as scale triggers. They are SLO-breach paging signals, not scaling inputs.

### Non-Goals

- **No predictive / ML-based autoscaling.** Out of scope (Knative KPA panic-mode, ARIMA forecasters). Possibly revisited if leading-trigger reaction time (~75–135s) proves insufficient under real workload patterns.
- **No vLLM Production-Stack swap.** That's a separate, larger architecture decision tracked elsewhere; this spec keeps the Envoy AI Gateway routing surface unchanged.
- **No removal of the always-warm FIM model.** FIM (`xplane-qwen-coder-fim`) keeps `min=1` and direct routing, no scaling triggers added (sub-second TTFT requirement, latency-critical for IDE autocomplete).
- **No client-side retry SDK.** Demo `min=0` showcase requires the user to retry manually; we do not ship a wrapper.
- **No removal of the `keda-add-ons-http` HelmRelease in this iteration.** Marked for cleanup in a follow-up — out of scope to keep this PR's blast radius bounded.

---

## Success Criteria

- **SC-001**: All 4 vLLM models deploy at `minReplicas=1` after Flux reconcile of the new composition tag. Verified by `kubectl get deploy -n llm` (READY=1/1 within 5min for each `xplane-*` model).
- **SC-002**: Sustained synthetic load (8 concurrent requests of ~2k context for 90s against `xplane-qwen-coder`) triggers a 1→2 scale-up within 120s of load start, **before** `vllm:num_requests_waiting` series fires. Verified by `kubectl get deploy xplane-qwen-coder -n llm` and a VictoriaMetrics query showing `vllm:num_requests_waiting` stayed at 0 throughout the load window.
- **SC-003**: Single 32k-context request triggers scale-up via the cache-utilisation trigger alone (running-count trigger remains < threshold). Verified by panic-loading `xplane-qwen3-8b` with one synthetic 31k-token prompt and observing `gpu_cache_usage_perc > 0.6` followed by deployment scale-up.
- **SC-004**: After 10min of zero traffic, all models remain at `minReplicas=1` (no scale-down to 0). `kubectl get deploy -n llm` after a 15min idle window shows READY=1/1 for all 4.
- **SC-005**: `kubectl get httproute -n llm` shows no `llm-fleet-keda-*` plain HTTPRoutes (only the AIGatewayRoute-generated routes). The `keda-interceptor` Backend exists or doesn't (cleanup-iteration choice), but is not referenced by any AIServiceBackend.
- **SC-006**: VMRule fires alert `LLMQueueDepthSustained` if `vllm:num_requests_waiting > 0` for 60s — proven by manually scaling a model to 0, sending a request, and observing the alert in `vmalertmanager`.
- **SC-007**: Composition `inference-service` test (`main_test.k`) covers the new `ScaledObject` shape, including the running-count and cache triggers. `./scripts/validate-kcl-compositions.sh` exits 0.

---

## Constraints / Dependencies

- KEDA core 2.x already deployed (we keep it); the add-on `keda-add-ons-http` is no longer required by the LLM platform after this change.
- VictoriaMetrics already scraping vLLM `/metrics` via the composition-emitted `VMServiceScrape`.
- AI Gateway v0.5.x routing semantics (AIGatewayRoute auto-generates `urlRewrite.hostname.type: Backend`) — this is now a feature, not a workaround: the Backend FQDN equals the vLLM Service hostname, so the rewrite Just Works for direct routing.
- vLLM's `max-num-seqs` config — currently defaulted via the composition; must surface as a composition input so the scaling threshold can compute the running/max ratio correctly.

---

## Open questions

None at this stage. Triggers, thresholds, and `cooldownPeriod` were discussed in brainstorming and are reflected in FR-001 / FR-004. Any tuning becomes runtime ops, not spec change.
