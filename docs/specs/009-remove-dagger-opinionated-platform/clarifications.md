# Clarifications Log — Remove Dagger from the opinionated platform stack. Dagger's footprint is now low-ROI and partly redundant: the one CI step (dagger call pre-commit-tf) duplicates the native antonbabenko pre-commit-terraform hooks already in .pre-commit-config.yaml, while the heavyweight parts — the in-cluster dagger-engine deployment (tooling/base/dagger-engine/) and a dedicated dagger GHA runner scale set (tooling/base/gha-runners/dagger-scale-set-helmrelease.yaml) — carry real maintenance surface (network policies, PDB, upgrades, a runner pool) for that thin benefit. SPEC-007 already moved manifest validation off its Dagger function onto a plain script (validate-manifests.sh). Scope: inventory every Dagger touchpoint (CI workflows, in-cluster engine, runner scale set, polaris/kustomization refs), confirm the pre-commit redundancy, define the teardown order, and decide whether to keep a minimal example for the blog's Dagger intro post. Rationale is low-ROI/redundancy, explicitly NOT trendiness or AI.

**Spec**: [SPEC-009](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-15 — <one-line question>

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

## CL-1 — 2026-07-15 — Do the self-hosted GitHub Actions runners stay?

**Asked by**: User
**Context**: Removing Dagger touches `tooling/base/gha-runners/`, which holds the
`dagger-gha-runner-scale-set` alongside the default scale set. Whether self-hosted runners
are in scope for removal decides FR-004 and SC-004.

**Decision**: The self-hosted runners STAY. They are independent of Dagger and out of scope
for this removal. Only the Dagger-*specific* configuration on the runner scale set (e.g. a
dagger engine sidecar/socket, dagger labels) is cleaned up if it becomes dead once Dagger
is gone; the runner pool itself is kept and, if needed, folded into / renamed from the
`dagger-` scale set to a neutral self-hosted scale set.
**Rationale**: Self-hosted runners serve the whole CI, not just Dagger jobs; the user runs
CI on them regardless of the pipeline tool.
**Decided by**: User (conversation, 2026-07-15)

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
