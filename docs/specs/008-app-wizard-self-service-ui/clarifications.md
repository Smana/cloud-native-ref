# Clarifications Log — App Wizard self-service UI

**Spec**: [SPEC-008](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID.

---

## CL-1 — 2026-07-14 — Build a custom UI, or adopt an existing self-service surface?

**Asked by**: Spec author (brainstorming session)
**Context**: "Form → GitOps PR" is the core use case of Internal Developer Portals; building bespoke needs justification.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Custom lightweight UI | Reference-platform value in demonstrating the pattern end-to-end; scope stays one form + one PR flow | Bespoke maintenance burden |
| B | Backstage software template | Industry standard, big ecosystem | Full portal adoption (catalog, auth, TS app) for one form |
| C | GitHub Issue Forms + Action | Zero hosting/auth; author traceability free | Flat forms, no progressive disclosure or live validation |
| D | Headlamp plugin | Reuses existing deployment + Tailscale auth | Cluster-oriented; Git PR flow bolted on |

**Decision**: A — custom lightweight UI, scope-fenced (not a portal)
**Rationale**: This is a reference platform; the schema-driven-form pattern is the demonstrable artifact. B/C remain the honest recommendations for teams that don't need to own the pattern.
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: spec.md Non-Goals; challenge section of the design discussion

## CL-2 — 2026-07-14 — Hand-crafted form or generated from the XRD?

**Asked by**: Spec author (brainstorming session)
**Context**: SPEC-007 changed the App schema the day before this brainstorm; any hand-built form would already be stale. The module README had drifted from the schema for the same reason.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Generated from XRD + `ui-hints.yaml` overlay | Zero drift; new fields appear automatically; CEL → live validation | Less pixel-level control; hints file to maintain |
| B | Hand-crafted form | Max UX control | Every XRD change requires a UI release; drift guaranteed |
| C | Hybrid (hand-built basic, generated advanced) | Polished first screen | Two rendering paths to test |

**Decision**: A — fully generated, presentation-only hints overlay
**Rationale**: Drift is the failure mode with evidence in this repo (README, fixed in SPEC-007 T015). Hints control tiers/grouping/labels only, so UX polish stays possible without forking field knowledge.
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: FR-001..003, SC-002

## CL-3 — 2026-07-14 — Whose identity opens the PR?

**Asked by**: Spec author (brainstorming session)
**Context**: Audit trail and the entire authz design hinge on PR authorship.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | User's GitHub identity (OAuth) | Perfect audit trail; GitHub permissions are the authz model; no bot secret | Users need repo access; OAuth consent |
| B | Platform bot (GitHub App) | Works without user write access | Indirect audit; high-value token to protect |
| C | Hybrid | Covers both | Two auth systems |

**Decision**: A — user's own identity end-to-end
**Rationale**: The wizard adds no RBAC of its own and holds no long-lived credentials; blame/CODEOWNERS/revert accountability all point at the human.
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: FR-004, FR-014

## CL-4 — 2026-07-14 — How much LLM in v1?

**Asked by**: Smaine ("would it be interesting to plug it to an LLM?")
**Context**: LLM assist can remove blank-form friction, but must not turn a deterministic tool into a probabilistic one.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Prefill + network-policy suggester | Bounded, schema-constrained, optional; dogfoods the platform LLM stack | Two prompts to maintain + eval |
| B | Prefill only | Smallest surface | Leaves the hardest field (policies) unassisted |
| C | No LLM in v1 | Lowest risk | Loses differentiator |
| D | Conversational wizard | Novel | Slower than a form, opaque to reviewers, probabilistic authority |

**Decision**: A — two bounded assists, as Phase 3, structurally optional
**Rationale**: The LLM is an input accelerator, never an authority: output is constrained by the XRD-derived JSON schema, badged, and everything passes the same validation gates. D explicitly rejected.
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: FR-011, SC-007, US-5

## CL-5 — 2026-07-14 — Create-only, or day-2 operations too?

**Asked by**: Spec author (brainstorming session)
**Context**: Create-only self-service tools get used once per app and abandoned; day-2 (tag bump, env var) is the recurring need — but requires YAML round-trip fidelity.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Create + edit (+ decommission) | Retention feature; wizard remains useful after day 1 | Structure-preserving YAML round-trip complexity |
| B | Create-only v1 | Smaller | Devs face raw YAML at first tag bump |
| C | Create + tag-bump only | 80% of day-2 PRs | Odd UX boundary |

**Decision**: A — full day-2 as Phase 2, including decommission (removal PRs)
**Rationale**: Orphaned apps are the untold cost of self-service; decommission was added during design (spec §8). Round-trip fidelity is testable (SC-005).
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: US-4, FR-009, SC-005

## CL-6 — 2026-07-14 — What is a "stack"?

**Asked by**: Spec author (brainstorming session)
**Context**: `apps/<stack>/<app_name>` makes stack load-bearing: folder, namespace, review routing.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Registry entry: name/description/namespace/owner team, platform-owned file | No typo-stacks; namespace + CODEOWNERS derive from it | New stack = separate platform PR |
| B | Free-form folder | Simplest | Stack proliferation, no routing semantics |
| C | No stacks in v1 | YAGNI | Restructuring Flux-watched paths later |

**Decision**: A — `apps/stacks.yaml` registry, dropdown in the form, stack creation out of wizard scope
**Rationale**: Stacks carry namespace and review-ownership semantics, so their creation deserves platform review; the wizard consuming a registry keeps it deterministic.
**Decided by**: Smaine (brainstorming, 2026-07-14)
**References**: FR-006, T002

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
