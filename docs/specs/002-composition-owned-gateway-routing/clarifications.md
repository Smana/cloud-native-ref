# Clarifications Log — Composition-owned AI Gateway routing with weighted LoRA canary for InferenceService

**Spec**: [SPEC-002](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-07 — <one-line question>

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

## CL-1 — 2026-07-07 — What should weighted canary support in v1?

**Asked by**: Spec author (brainstorming session)
**Context**: A canary between two full model deployments costs a second GPU node while it runs; LoRA adapters already serve from the same pod as their base model at zero extra GPU cost.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | LoRA adapter canary only | Zero GPU cost; smallest useful step; exercises the whole weighted-routing machinery | No full-model rollout story yet |
| B | Claim-vs-claim canary | Classic rollout semantics | Doubles GPU while running; cross-claim references in the XRD |
| C | Both | Most general | Largest API surface and test matrix in one branch |
| D | No canary in v1 | Smallest diff | Ships route ownership without the headline feature |

**Decision**: A — LoRA adapter canary
**Rationale**: Proves `weight` + `modelNameOverride` end-to-end at zero marginal cost; claim-vs-claim composes on top later without API breakage.
**Decided by**: User (brainstorming, 2026-07-07)
**References**: Envoy AI Gateway `AIGatewayRouteRuleBackendRef.modelNameOverride`; existing `loraAdapters` support (composition v0.6.0)

## CL-2 — 2026-07-07 — Is external SaaS fallback in scope?

**Asked by**: Spec author (brainstorming session)
**Context**: Modelplane's design routes to managed providers (Groq/Together) as fallback endpoints; Envoy AI Gateway supports this natively (`BackendSecurityPolicy`, backendRef `priority`).

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Defer to follow-up | Keeps this branch focused; fallback is additive on composition-owned routes | Hybrid story waits |
| B | In scope, minimal | Ships the hybrid story now | Drags in API-key secrets, gateway egress CNPs, cost-tracking questions |
| C | Design-only now | Avoids API churn later | Speculative design |

**Decision**: A — defer
**Rationale**: Fallback is just another backend type on a route the composition will own after this spec; no API shape needs reserving beyond the already-existing upstream `priority` field.
**Decided by**: User (brainstorming, 2026-07-07)

## CL-3 — 2026-07-07 — Migration strategy from hand-written route.yaml?

**Asked by**: Spec author (brainstorming session)
**Context**: `apps/base/ai/llm/ai-gateway-routes/route.yaml` currently defines backends + one fleet `AIGatewayRoute` for all 4 models incl. LoRA-name pin rules. The cluster serves live traffic during migration.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Opt-in flag, migrate one model on this branch | Matches platform opt-in philosophy; cluster keeps serving; small reviewable diff | Fleet route lingers until follow-up |
| B | Big-bang, delete route.yaml in same PR | Clean end-state immediately | Route replacement under live traffic; large diff |
| C | Composition renders backends, fleet route stays hand-written | Smallest change | Permanent split-brain |

**Decision**: A — opt-in flag (`gateway.enabled`), migrate `xplane-qwen-coder` (owns the LoRA adapters, proving canary), remove its fleet-route entries in the same commit to avoid duplicate header matches.
**Decided by**: User (brainstorming, 2026-07-07)

## CL-4 — 2026-07-07 — Per-claim route vs fleet-router XR vs ungated rendering?

**Asked by**: Spec author (brainstorming session)
**Context**: Modelplane separates `ModelService` (routing) from `ModelDeployment` (serving) as distinct composites and withholds endpoints until replicas are Ready.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Per-claim `AIGatewayRoute`, readiness-gated with latch | Self-contained claim; GC on delete; existing `ocds` idiom; no route flapping | Multiple AIGatewayRoutes on one Gateway (standard, rules merge) |
| B | Separate fleet-router XRD + extra-resources function | Faithful ModelService split; natural home for cross-claim canary/fallback | Second XRD/composition/OCI module + new function dep — over-machinery for one cluster |
| C | Per-claim route, no readiness gate | Smaller KCL diff | 404/503 window on brand-new claims |

**Decision**: A — per-claim route rendered by the existing composition; `AIGatewayRoute` withheld until Deployment `Available=True` OR already present in `ocds` (create-time gate, latched thereafter).
**Rationale**: Expresses Modelplane's readiness-withheld-endpoint idea in the composition's existing single-module idiom; the latch prevents route deletion on transient unavailability (Envoy's 503-on-empty-endpoints is the correct signal then).
**Decided by**: User (brainstorming, 2026-07-07)
**References**: Modelplane `design/design.md` (ModelService), `compose-model-deployment` endpoint withholding (their issue #102)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
