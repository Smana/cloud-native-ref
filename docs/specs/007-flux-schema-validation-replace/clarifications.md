# Clarifications Log — Flux schema validation: replace kubeconform/Datree with the flux-schema plugin, render Kustomize+Helm into a single bundle validated by flux schema and Polaris, eliminate silent schema skips

**Spec**: [SPEC-007](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

<!-- Template for each entry:

## CL-N — 2026-07-13 — <one-line question>

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

## CL-1 — 2026-07-13 — Validate raw repository files, or rendered Kustomize output?

**Asked by**: Spec author (spike)
**Context**: The spike validated raw files and produced false positives on `security/mycluster-0/external-secrets/helmrelease.yaml` ("missing property 'interval'") and `tooling/base/dagger-engine/deployment.yaml` (`cpu: 1` — "got number, want string"). Inspection confirmed the first is a strategic-merge patch fragment: `security/mycluster-0/external-secrets/kustomization.yaml:8` references it under `patches: - path:`. A patch is a partial resource by definition and can never satisfy a full schema.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Validate rendered `kustomize build` output | Validates what Flux actually applies; patch fragments are merged away; no false positives | Requires a render step before validation |
| B | Validate raw files, skip patch paths by glob | No render step | Every new patch needs a manual exclusion; drifts silently; still validates something Flux never applies |
| C | Validate both | Maximum coverage | Option B's false positives on every run |

**Decision**: A — validate rendered Kustomize output (plus standalone manifests that belong to no overlay).
**Rationale**: Flux applies the rendered result, so that is the only artifact worth asserting on. This is also what makes FR-004's renderer load-bearing rather than incidental — it serves both gates. Directly supports SC-001.
**Decided by**: Conversation, 2026-07-13
**References**: FR-004, FR-007; upstream `flux-schema` `validate.sh` renders overlays for the same reason

## CL-2 — 2026-07-13 — Cache the rendered bundle / Helm charts in CI?

**Asked by**: Spec author
**Context**: FR-004 renders 41 HelmReleases, which means pulling charts from HelmRepository/OCIRepository on every PR run. That is network I/O on the critical path of every CI run.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Render fresh every run; cache only the Helm repo cache dir (`~/.cache/helm`) via `actions/cache` | Output always reflects the PR's actual manifests; chart versions are pinned so results are deterministic; cache cuts wall-clock without affecting correctness | Cold cache is slower on first run after a chart bump |
| B | Commit the rendered bundle to the repo, regenerate on change | Fastest CI | The bundle becomes a second source of truth that will drift; large, noisy diffs on every chart bump |
| C | Cache the rendered bundle keyed by manifest hash | Fast | Cache-key bugs produce stale validation — a silently-wrong green, which is the exact failure class this spec exists to remove |

**Decision**: A — render fresh, cache only the Helm chart cache.
**Rationale**: This spec's entire purpose is eliminating silently-wrong greens (see *Problem*). Option C reintroduces that class through a cache key; Option B reintroduces it through drift. Rendering is deterministic because every chart version is pinned, so caching the download layer is free correctness-wise.
**Decided by**: Conversation, 2026-07-13
**References**: FR-004; SC-001

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
