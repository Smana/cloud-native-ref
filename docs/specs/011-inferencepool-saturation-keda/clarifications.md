# Clarifications Log — Opt-in InferencePool saturation autoscaling (KEDA)

**Spec**: [SPEC-011](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-18 — How to handle the EPP dependency of the saturation gauge?

**Asked by**: User (recency-assessment session)
**Context**: The InferencePool saturation gauge is emitted **only** by the EndpointPicker (EPP). The EPP is [SPEC-004](../004-per-inferenceservice-inferencepool-endpoint/spec.md), opt-in, default-off, and enabled on **zero** models today. There is no independent pool controller emitting the gauge. So a KEDA trigger sourced from it can only be live where the EPP runs — the spec must decide how to handle that dependency.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Gate the new trigger on `endpointPicker.enabled`; non-EPP models keep the 3 raw triggers | No forced EPP rollout; strictly opt-in and non-breaking; composes with SPEC-004; respects CEL-exclusivity with `canaries[]` | Saturation-based scaling only available on EPP-enabled models |
| B | Make the EPP a fleet-wide prerequisite; saturation gauge becomes the primary KEDA signal | One clean signal everywhere; retires the inert cache trigger (per SPEC-001's finding) fleet-wide | Large blast radius; forces dropping `canaries[]` on `qwen-coder`; SPEC-004 still draft; EPP becomes mandatory |
| C | Defer the whole spec until SPEC-004 GA | No work now | Loses the chance to validate the signal on the first EPP-enabled model; the inert-cache-trigger problem lingers |

**Decision**: **A** — gate the new trigger on the EPP (opt-in).
**Rationale**: Keeps the change non-breaking and layered on top of SPEC-004's default-off EPP. Non-EPP models (the majority, incl. `canaries[]` models that are CEL-blocked from the EPP) are untouched. Lets us empirically validate the pool saturation signal (SPEC-001 flags the cache trigger as dead weight on L4 GPUs) before considering a broader replacement (tracked as a deferred follow-up in FR-007 / spec Open question 3).
**Decided by**: User, recency-assessment session, 2026-07-18.
**References**: SPEC-004 (EPP opt-in, FR-001 "default MUST be off"); SPEC-001 (cache trigger inert on L4); spec.md FR-001/FR-002.

---

<!-- Remaining open questions (exact saturation gauge metric name, default saturationThreshold,
     ADD-vs-REPLACE long term) are tracked in spec.md "Open questions" and appended here as
     subsequent CL-N entries once resolved via /clarify. -->

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
