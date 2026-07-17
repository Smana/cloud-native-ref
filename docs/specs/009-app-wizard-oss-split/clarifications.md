# Clarifications Log — Extract app-wizard into a standalone agnostic open-source repository

**Spec**: [SPEC-009](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-17 — <one-line question>

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

## CL-1 — 2026-07-17 — How agnostic should the open-source wizard be?

**Asked by**: User
**Context**: The wizard could be split at three levels of generality; this decision sets the scope for every downstream task (what gets parametrized vs. rewritten vs. left alone).

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Configurable ogenki wizard (parametrize defaults + branding only) | Lowest effort | Still assumes the ogenki App XRD shape; not truly generic |
| B | **Generic Crossplane-claim wizard** (any XRD → PR; GVK from XRD; themeable; config file; optional render) | Genuinely adoptable; achievable — form/validation/PR/provider are already schema-generic | Medium effort: remove hardcodes, theme, config file, docs |
| C | Generic Kubernetes-CRD wizard (drop Crossplane; kustomize/kubeconform preview) | Maximally generic | Loses the crossplane-render value prop; large rewrite; YAGNI |

**Decision**: B — Generic Crossplane-claim wizard.
**Rationale**: The hard parts are already generic (XRD-schema-driven form, OpenAPI+CEL validation, `gitprovider.Provider` interface, pluggable auth). The only real coupling is hardcoded defaults, the claim GVK, branding, and the render engine — all removable at medium effort. Level C throws away the tool's core value (showing what a claim composes into). cloud-native-ref becomes the reference config.
**Decided by**: User (brainstorming session, 2026-07-17)
**References**: spec.md Summary, NG-1

## CL-2 — 2026-07-17 — Configuration mechanism for operators?

**Asked by**: Spec author
**Context**: Level B introduces ~a dozen new knobs (repo, XRD path, stacks, layout template, branding, render toggle, assist settings) on top of the existing ~15 env vars. How operators supply them shapes the tool's API surface.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **`wizard.yaml` config file + env for secrets** | Self-documents the surface; cleaner than ~25 env vars; a repo can check in its config | One more mount; need file+env precedence rules |
| B | Pure env vars (12-factor) | No mounted file; keeps current approach | ~25 env vars is unwieldy and undocumented |

**Decision**: A — `wizard.yaml` for all non-secrets, secrets remain env-only, env overrides file values.
**Rationale**: The tool's configuration surface is large and structured (nested branding/theme, render paths); a file self-documents it and is what an OSS adopter expects. Keeping secrets env-only preserves NFR-002 (secrets never in the config file). Env-overrides-file keeps 12-factor deployability.
**Decided by**: User (brainstorming session, 2026-07-17)
**References**: FR-002, NFR-002

## CL-3 — 2026-07-17 — License for the open-source repo?

**Asked by**: Spec author
**Context**: The repo needs a license to be a credible OSS project (US-4, FR-007).

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Apache-2.0** | Explicit patent grant; CNCF-ecosystem default (Crossplane, Flux, Kubernetes) | Slightly longer than MIT |
| B | MIT | Shortest, maximally permissive | No explicit patent grant; less conventional for infra |

**Decision**: A — Apache-2.0.
**Rationale**: Best fit for an infra tool adopted in production; matches the license of the ecosystem it plugs into (Crossplane/Flux/Kubernetes).
**Decided by**: User (brainstorming session, 2026-07-17)
**References**: FR-007

## CL-4 — 2026-07-17 — Preserve git history in the extraction?

**Asked by**: Spec author
**Context**: The extracted tree can carry its cloud-native-ref history or start clean.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | **Preserve via `git filter-repo`** | Honest provenance (the #1590/#1622 render-engine saga, authorship); paths rewritten to root | Requires filter-repo; slightly more mechanical care |
| B | Clean single initial commit | Simplest | Loses development history |

**Decision**: A — preserve history via `git filter-repo`.
**Rationale**: The wizard has a meaningful development history worth keeping for an OSS project; provenance builds trust (US-4).
**Decided by**: User (brainstorming session, 2026-07-17)
**References**: FR-009, SC-008

## CL-5 — 2026-07-17 — Who creates and pushes the public repo?

**Asked by**: User
**Context**: Creating a public GitHub repo is an outward-facing action; needs to be assigned.

**Decision**: `gh` (authenticated as Smana, confirmed `repo` + `workflow` scopes) creates and pushes `Smana/app-wizard`. To de-risk first impressions, the repo is created **private**, brought to green CI + finished README, then flipped **public** after user review.
**Rationale**: `gh` has the rights; the private-first flip avoids a public repo with a broken initial state.
**Decided by**: User (brainstorming session, 2026-07-17)
**References**: FR-007, T-tasks in plan.md

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
