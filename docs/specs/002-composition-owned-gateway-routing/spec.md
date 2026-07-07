# Spec: Composition-owned AI Gateway routing with weighted LoRA canary for InferenceService

**ID**: SPEC-002
**Issue**: [#1558](https://github.com/Smana/cloud-native-ref/issues/1558)
**Status**: draft
**Type**: composition
**Created**: 2026-07-07
**Last updated**: 2026-07-07

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Move Envoy AI Gateway route rendering (`Backend`, `AIServiceBackend`, `AIGatewayRoute`) into the InferenceService composition behind an opt-in `gateway` block, and add weighted canary routing between a base model and one of its LoRA adapters. Inspired by Modelplane's `ModelService`/`ModelEndpoint` design (routing owned by the platform, endpoints withheld until the workload is ready) — including the weighted routing Modelplane designed but has not implemented.

---

## Problem

Every InferenceService claim today requires a second, manual edit: its `Backend`, `AIServiceBackend`, and `AIGatewayRoute` rules live in the hand-written `apps/base/ai/llm/ai-gateway-routes/route.yaml`. This is two sources of truth — a claim can exist with no route (silent 404) or a route can outlive its claim (dangling backend). Nothing gates route creation on workload readiness, so a brand-new model 404s/503s until its first replica is up. And there is no traffic-splitting mechanism at all: LoRA adapters (`sql-dpo`, `securecode`) can only be reached by clients that explicitly request the adapter model name — there is no way to progressively shift a fraction of base-model traffic onto an adapter to validate it against real traffic, even though the adapters serve from the same pod at zero extra GPU cost.

---

## User Stories

### US-1: Self-contained model claims (Priority: P1)

As a **platform user deploying a model**, I want **a single InferenceService claim to also publish its gateway route**, so that **deploying or deleting a model is one operation with no manual route bookkeeping**.

**Acceptance Scenarios**:
1. **Given** a new InferenceService claim with `gateway.enabled: true`, **When** the claim becomes Ready, **Then** `Backend`, `AIServiceBackend`, and `AIGatewayRoute` exist for it and OpenAI-compatible requests for its model name succeed through the gateway.
2. **Given** a claim with `gateway.enabled: true`, **When** the claim is deleted, **Then** its routing resources are garbage-collected with it (no dangling route).
3. **Given** a brand-new claim whose Deployment is not yet Available, **When** a client requests the model, **Then** no route exists yet (the route appears only after the first replica can serve).

### US-2: LoRA canary rollout (Priority: P1)

As a **model operator**, I want **a weighted split of base-model traffic to a LoRA adapter**, so that **I can validate a fine-tune on real traffic without clients changing model names and without extra GPU cost**.

**Acceptance Scenarios**:
1. **Given** `gateway.canary: {adapter: sql-dpo, weightPercent: 10}` on `xplane-qwen-coder`, **When** clients send requests for model `xplane-qwen-coder`, **Then** ≈10% are served by the `xplane-qwen-coder-sql-dpo` adapter (verified via `vllm:lora_requests_info`) and ≈90% by the base model, with no client-visible change.
2. **Given** the same canary config, **When** a client explicitly requests `xplane-qwen-coder-sql-dpo`, **Then** the request is pinned to the adapter (100%), unaffected by the split.
3. **Given** a canary referencing an adapter name not present in `loraAdapters`, **When** the claim is applied, **Then** the API server rejects it at admission (CEL validation).

### US-3: Gradual migration (Priority: P2)

As the **platform maintainer**, I want **claims to opt in one at a time**, so that **the live fleet keeps serving while route ownership moves into the composition**.

**Acceptance Scenarios**:
1. **Given** one claim migrated to `gateway.enabled: true` and its entries removed from the fleet route, **When** clients request any of the four fleet models (directly or via MoM), **Then** all resolve exactly as before the migration.

---

## Requirements

### Functional

- **FR-001**: The composition MUST render `Backend` (FQDN of the claim's Service, port 8000), `AIServiceBackend` (OpenAI schema), and `AIGatewayRoute` (parentRef `ai-gateway/envoy-ai-gateway-system`) when `spec.gateway.enabled` is true. Default MUST be off (opt-in).
- **FR-002**: The `AIGatewayRoute` MUST be withheld until the claim's Deployment reports `Available=True`, and MUST NOT be withdrawn on subsequent transient unavailability once it exists (create-time gate with latch via `ocds`).
- **FR-003**: When `spec.gateway.canary` is set, the base-model rule MUST split traffic `100-weightPercent` / `weightPercent` between the base backend and a canary `AIServiceBackend` carrying `modelNameOverride: <claim>-<adapter>`; both reference the same `Backend`.
- **FR-004**: Each `loraAdapters[]` entry MUST get a pinned route rule (`x-ai-eg-model: <claim>-<adapter>` → base backend, weight 100), preserving current explicit-adapter routing regardless of canary state.
- **FR-005**: XRD CEL validation MUST reject: `canary` without `gateway.enabled`; `canary.adapter` not present in `loraAdapters[].name`; `weightPercent` outside 1–99.
- **FR-006**: `status.modelEndpoint` MUST be set to the gateway URL when `gateway.enabled` is true.
- **FR-007**: The Crossplane aggregate ClusterRole MUST grant the new kinds (`gateway.envoyproxy.io/backends`, `aigateway.envoyproxy.io/aigatewayroutes,aiservicebackends`).
- **FR-008**: Routing for `model: MoM` (semantic router) MUST keep working unchanged for migrated and unmigrated models alike.

### Non-Goals

- External SaaS fallback backends (deferred; the `priority` field on `AIGatewayRouteRuleBackendRef` is the natural follow-up seam).
- Claim-vs-claim canary (weighted split between two InferenceService claims).
- A separate fleet-router XRD (Modelplane's `ModelService` as its own composite) — rejected as over-machinery for a single cluster.
- Migrating all four models: this spec migrates `xplane-qwen-coder` only; the rest plus `route.yaml` deletion is a follow-up PR.
- GAIE `InferencePool`/endpoint-picker routing.

---

## Success Criteria

- **SC-001**: `xplane-qwen-coder` serves through a composition-rendered route: its `AIGatewayRoute` exists with `ownerReferences` to the XR, its entries are gone from `route.yaml`, and a chat completion for `xplane-qwen-coder` through the gateway returns 200.
- **SC-002**: With `weightPercent: 10` and ≥50 base-model requests, `vllm:lora_requests_info` shows the sql-dpo adapter served between 2% and 25% of them (binomial tolerance), and explicit `xplane-qwen-coder-sql-dpo` requests hit the adapter 100%.
- **SC-003**: A claim applied with a bogus `canary.adapter` is rejected at admission with a CEL message naming the field.
- **SC-004**: On a fresh claim with `gateway.enabled: true`, the `AIGatewayRoute` is absent while the Deployment is unready and appears within one reconcile of `Available=True`; deleting the claim removes all three routing resources.
- **SC-005**: `model: MoM` requests still classify and resolve to every fleet model (migrated and unmigrated) — no semantic-router config change.
- **SC-006**: `./scripts/validate-kcl-compositions.sh` exits 0; `main_test.k` covers the new rendering paths (enabled/disabled, gated/latched, canary weights, adapter pin rules).

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] Observation (non-blocking, resolved during T010 e2e): do Envoy AI Gateway token/cost metrics attribute canary traffic to the overridden adapter name or the base model name? Document the answer in the composition README either way.

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — Canary scope: LoRA adapter split first (same pod, zero GPU); claim-vs-claim deferred.
- CL-2 — External SaaS fallback deferred to a follow-up spec.
- CL-3 — Migration: opt-in flag, one model (`xplane-qwen-coder`) on this branch.
- CL-4 — Approach: per-claim AIGatewayRoute rendered by the existing composition, readiness-gated with latch (fleet-router XR rejected).

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar spec: [SPEC-001 — LLM platform prometheus autoscaling](../0001-llm-platform-prometheus-autoscaling/spec.md)
- Inspiration: [Modelplane design docs](https://github.com/modelplaneai/modelplane) — `design/design.md` (ModelService/ModelEndpoint), readiness-withheld endpoints; their weighted routing is designed but unimplemented (modelplane#90)
- Envoy AI Gateway v1.0.0 `AIGatewayRouteRuleBackendRef`: `weight`, `modelNameOverride`, `priority`
