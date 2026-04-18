# Clarifications Log — [Title]

**Spec**: [SPEC-XXX](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — YYYY-MM-DD — <one-line question>

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

<!-- Example:

## CL-1 — 2026-04-18 — Default eviction policy for cache?

**Asked by**: Spec author
**Context**: Valkey fills memory eventually. Eviction policy determines what happens at the limit.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `allkeys-lru` | Community default; predictable; satisfies SC-002 | None relevant at our scale |
| B | `volatile-lru` | Safer for persistent keys | Most of our use is ephemeral |
| C | `noeviction` | Explicit OOM | Breaks dependent apps |

**Decision**: A — `allkeys-lru`
**Rationale**: Valkey/Redis community default; satisfies SC-002 "evictions deterministic"; matches operator expectations across the team.
**Decided by**: Platform team (/clarify session, 2026-04-18)
**References**: <https://valkey.io/topics/lru-cache/>; SC-002 in spec.md

-->

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
