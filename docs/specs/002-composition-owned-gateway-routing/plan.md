# Plan: Composition-owned AI Gateway routing with weighted LoRA canary for InferenceService

**Spec**: [SPEC-002](spec.md)
**Status**: draft
**Last updated**: 2026-07-07

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

New optional `gateway` block on `InferenceService` (composition v0.6.0 → v0.7.0):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen-coder
  namespace: llm
spec:
  # ... existing fields unchanged ...
  loraAdapters:
    - name: sql-dpo
      repository: org/qwen-coder-sql-dpo

  gateway:
    enabled: true            # Optional, default: false (opt-in)
    canaries:                # Optional array (maxItems: 4); requires gateway.enabled
      - adapter: sql-dpo     # Must match a loraAdapters[].name (CEL)
        weightPercent: 10    # 1–99; % of base-model traffic to the adapter
```

Root-level XRD CEL validations (all reject at admission, FR-005 — CL-6):
- `!has(self.gateway.canaries) || self.gateway.enabled`
- `!has(self.gateway) || !has(self.gateway.canaries) || (has(self.loraAdapters) && self.gateway.canaries.all(c, self.loraAdapters.exists(a, a.name == c.adapter)))`
- distinct adapter names: `self.gateway.canaries.all(c, self.gateway.canaries.filter(x, x.adapter == c.adapter).size() == 1)`
- weight-sum guard: `self.gateway.canaries.map(c, c.weightPercent).sum() <= 99`
- `weightPercent` schema bounds: `minimum: 1`, `maximum: 99`

`status.modelEndpoint` = `https://llm.${private_domain_name}/v1` when `gateway.enabled` (FR-006).

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| `Backend` `<name>-direct` (gateway.envoyproxy.io/v1alpha1) | `gateway.enabled` | `fqdn: <name>.<ns>.svc.cluster.local:8000`; static-ready |
| `AIServiceBackend` `<name>` (aigateway.envoyproxy.io/v1alpha1) | `gateway.enabled` | `schema: OpenAI` → Backend; static-ready |
| `AIServiceBackend` `<name>-canary-<i>` | per `gateway.canaries[]` entry | Same Backend ref; one per canary to carry a distinct backendRef name in the rule |
| `AIGatewayRoute` `<name>` | `gateway.enabled` AND (Deployment `Available=True` in `ocds` OR route already in `ocds`) | parentRef `ai-gateway/envoy-ai-gateway-system`; readiness from `status.conditions[Accepted]` (HTTPRoute-style check) |

`AIGatewayRoute` rules:
1. Base rule — match `x-ai-eg-model: <name>`:
   - no canaries: `[{name: <name>, weight: 100}]`
   - canaries: `[{name: <name>, weight: 100-sum(w)}]` + one `{name: <name>-canary-<i>, modelNameOverride: <adapter-name-verbatim>, weight: w_i}` per entry (CL-5, CL-6)
2. Per `loraAdapters[]` entry — match `x-ai-eg-model: <loraAdapters[].name>` (verbatim, CL-5) → `[{name: <name>, weight: 100}]` (pin, FR-004). Rendered for ALL adapters whenever `gateway.enabled`, independent of canary.

### Key Entities

- **Readiness latch**: `_route_live = "aigatewayroute" in option("params").ocds`; `_deploy_available` from the existing Deployment readiness helper. Render route iff `_deploy_available or _route_live`. Create-time gate only — never withdraws a live route (CL-4).
- **Canary backendRefs**: a separate `AIServiceBackend` per canary entry (`<name>-canary-<i>`) per CL-4 note — one rule must not repeat the same backendRef name twice (CL-6).
- **modelNameOverride**: rewrites `body.model` at the gateway so vLLM serves the adapter; clients keep sending the base name. Value = the adapter's `loraAdapters[].name` verbatim — names are fully-qualified by convention (CL-5). Confirmed present in Envoy AI Gateway v1.0.0 (`AIGatewayRouteRuleBackendRef`).

### Dependencies

- [ ] Envoy AI Gateway v1.0.0 installed (already: `flux/sources/ocirepo-envoy-ai-gateway.yaml`)
- [ ] Aggregate ClusterRole grants for `gateway.envoyproxy.io` (`backends`) and `aigateway.envoyproxy.io` (`aigatewayroutes`, `aiservicebackends`) in `infrastructure/base/crossplane/providers/additional-rbac.yaml` (FR-007 — Crossplane v2 trap #3)
- [ ] No CNP change (serving CNP already allows Envoy data-plane ingress); no `ManagedResourceActivationPolicy` change (native kinds via function-kcl)
- [ ] No semantic-router change (ext-proc rewrite happens before route matching; SR only emits base model names — FR-008)

### Alternatives considered

Fleet-router XRD (Modelplane `ModelService` faithful) and ungated rendering — rejected in CL-4. Big-bang migration rejected in CL-3.

---

## Implementation Notes

- KCL: inline-conditional dict construction only (function-kcl #285 — no post-creation mutation); single-line list comprehensions; rename loop vars in dict comprehensions (shadowing trap).
- Migration commit must remove `xplane-qwen-coder`'s 3 rules + `Backend` + `AIServiceBackend` from `apps/base/ai/llm/ai-gateway-routes/route.yaml` in the same change that enables `gateway` on the claim — no duplicate `x-ai-eg-model` match may exist at any point (CL-3).
- Composition OCI publish flow: `kcl.mod` version bump to 0.7.0; PR-prefix tag rewritten by `crossplane-modules.yml`; verify anonymous pull before pointing the composition at it.
- Feature-branch cluster: deploy with `TF_VAR_flux_git_ref='refs/heads/<branch>'`; after merge, restore the branch or cut the FluxInstance to main before the head branch auto-deletes.
- Open observation (spec Open questions): whether gateway token/cost metrics attribute canary traffic to the overridden name — check `envoy_ai_gateway` metrics labels during T010 and document in README.
- Rollback path: set `gateway.enabled: false` (or revert the claim) and restore the model's entries in `route.yaml` — the fleet route is untouched for unmigrated models, so rollback is a single revert commit with no composition re-publish.

### File structure (composition)

```
infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k                 # + _gateway_resources block, readiness latch
├── main_test.k            # + gateway/canary/gating cases
├── kcl.mod                # 0.7.0
├── settings-example.yaml  # + gateway example
└── README.md              # + gateway/canary docs incl. metrics-attribution note
examples/
├── inferenceservice-basic.yaml      # unchanged (gateway off by default)
└── inferenceservice-complete.yaml   # + gateway.enabled + canary
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders
- `crossplane render` with both examples succeeds
- `./scripts/validate-kcl-compositions.sh` exit 0 (4-stage incl. Polaris ≥ 85, kube-linter)
- `kubeconform` on rendered route trio

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: Prerequisites

- [ ] **T001**: Add aggregate ClusterRole rules for `gateway.envoyproxy.io/backends`, `aigateway.envoyproxy.io/{aigatewayroutes,aiservicebackends}` to `additional-rbac.yaml`; verify with `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list aigatewayroutes -A`
- [ ] **T002**: XRD: add `gateway` block schema + CEL validations (FR-005); bump examples

### Phase 2: Implementation

- [ ] **T003**: KCL: render `Backend` + `AIServiceBackend` (+ one `-canary-<i>` variant per `canaries[]` entry) under `gateway.enabled` (FR-001)
- [ ] **T004**: KCL: render `AIGatewayRoute` with base rule, per-canary weights summing with the base remainder (FR-003), per-adapter pin rules (FR-004); readiness latch via `ocds` (FR-002); `Accepted`-condition readiness check
- [ ] **T005**: KCL: set `status.modelEndpoint` when enabled (FR-006)
- [ ] **T006**: `main_test.k`: trio rendered when enabled; nothing rendered when disabled; route withheld (Deployment unavailable, absent from ocds); route latched (unavailable but present in ocds); single- and multi-canary weights sum to 100 with the base keeping the remainder; adapter pin rules present; naming `xplane-*`
- [ ] **T007**: Bump `kcl.mod` → 0.7.0; publish module; point composition at the new tag (verify anonymous pull)

### Phase 3: Migration & e2e (feature-branch cluster)

- [ ] **T008**: Enable `gateway: {enabled: true, canaries: [{adapter: sql-dpo, weightPercent: 10}]}` on `xplane-qwen-coder`; remove its entries from `route.yaml` (same commit)
- [ ] **T009**: e2e: SC-001 (route owned + 200 via gateway), SC-004 (gate + GC on a scratch claim), SC-005 (MoM unchanged)
- [ ] **T010**: e2e: SC-002 — ≥50 requests, verify split via `vllm:lora_requests_info`; observe gateway metric attribution for canary tokens; `hubble observe --verdict DROPPED` clean
- [ ] **T011**: SC-003 — apply claim with bogus adapter, capture CEL rejection

### Phase 4: Validation & Documentation

- [ ] **T012**: Basic + complete examples render with `crossplane render`
- [ ] **T013**: `./scripts/validate-kcl-compositions.sh` exit 0 (incl. Polaris ≥ 85)
- [ ] **T014**: README.md, `settings-example.yaml`, examples updated (incl. canary metrics-attribution finding)

### Deviations from plan

- 2026-07-07 — FR-003/FR-004 corrected mid-implementation: adapter model names are `loraAdapters[].name` verbatim, not `<claim>-<adapter>` (CL-5). Composition + tests + examples re-done accordingly.

<!-- Append as implementation surprises show up. Format:
- <2026-07-07> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (two sources of truth; no readiness gating; no traffic splitting)
- [x] User stories capture real user needs (US-1 self-contained claims, US-2 LoRA canary, US-3 live migration)
- [x] Acceptance scenarios are testable (each maps to an SC with a concrete command/metric)
- [x] Scope is well-defined (Non-Goals: SaaS fallback, claim-vs-claim canary, fleet-router XRD, full migration, InferencePool)
- [x] Success criteria are measurable (SC-001…006, falsifiable per validator)

### Platform Engineer

- [x] Design follows existing patterns (extends the InferenceService module in place; `ocds` readiness idiom already used for Deployment/HTTPRoute)
- [x] API is consistent with other compositions (opt-in block with `enabled`, mirrors `route`/`preload` style)
- [x] Resource naming follows `xplane-*` convention (all rendered resources inherit the claim name; claims are `xplane-*`)
- [x] KCL avoids mutation pattern (design mandates inline-conditional dict construction — Implementation Notes)
- [x] Examples provided (basic stays gateway-off; complete gains `gateway` + canary — T012)

### Security & Compliance

- [x] Zero-trust networking (no new pods; existing default-deny serving CNP already allows Envoy data-plane ingress — unchanged)
- [x] Least-privilege RBAC (aggregate ClusterRole adds exactly 3 kinds needed by the composition — FR-007/T001)
- [x] Secrets via External Secrets (no new secrets introduced by this feature)
- [x] Security context enforced (no new pods; serving pod context unchanged)
- [x] IAM policies scoped to `xplane-*` resources (N/A — no AWS resources touched)

### SRE

- [x] Health checks defined (no new pods; route readiness derived from `AIGatewayRoute` `Accepted` condition)
- [x] Observability configured (VMServiceScrape unchanged; canary split observable via `vllm:lora_requests_info`; gateway metric attribution checked in T010)
- [x] Resource requests + limits appropriate (no new pods)
- [x] Failure modes documented (CEL admission rejections, 404-window prevention via gate, latch vs flapping, duplicate-match avoidance during migration)
- [x] Recovery / rollback path clear (disable flag + restore route.yaml entries — Implementation Notes)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/inference-service/` (this module, v0.6.0)
- Related: SPEC-001 (KEDA leading-signal autoscaling); Modelplane `design/design.md` + `design/unopinionated-deployments.md`
