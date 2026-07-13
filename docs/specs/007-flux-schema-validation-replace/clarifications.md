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

## CL-3 — 2026-07-13 — `flux schema` rejects numeric resource quantities the API server accepts. Mask, fix, or skip?

**Asked by**: Controller (during T005 execution)
**Context**: The first full gate run reported `resources/limits/cpu: got number, want string` on 5 documents — 3 from the upstream KEDA chart, 1 from the upstream Harbor chart, 1 from our own `tooling/base/dagger-engine/deployment.yaml`. All write `cpu: 1` rather than `cpu: "1"`.

These are **not defects**. Kubernetes' `resource.Quantity.UnmarshalJSON` parses bare numbers, so the API server accepts them. Conclusive evidence: KEDA and Harbor are running in `mycluster-0` right now with exactly these chart defaults. The reason kubeconform never flagged them is that `kubernetes-json-schema` types `Quantity` as `oneOf[string, number]`, whereas the flux-schema catalog types it as `string` only. The tool is stricter than the API server it claims to model.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Normalize numeric values to strings at quantity positions during rendering | Gate matches API-server semantics, which is what a gate should assert; no upstream charts to fight; full validation retained everywhere else | A (narrow, documented) transformation sits between the chart output and the gate |
| B | Override the upstream charts' values to quote every quantity | No renderer transformation | Fights upstream on every chart bump; unmaintainable; we would be "fixing" manifests that were never broken |
| C | `skipJSONPath` the `resources` blocks | Simple | Paths carry container indices (brittle), and it discards genuine validation of resource blocks — a real missing-limits bug would slip through |
| D | Leave the gate red | Honest | A permanently-red gate is a disabled gate |

**Decision**: A — normalize numeric quantities to strings during rendering, narrowly scoped to `resources.limits.*` / `resources.requests.*`, with the rationale commented in the code.
**Rationale**: The gate exists to answer "would the API server accept this?". The API server accepts it, so a faithful gate must too. Option B would have us modify correct manifests to satisfy a tool bug. Worth reporting upstream to `fluxcd/flux-schema`.
**Decided by**: Conversation, 2026-07-13
**References**: FR-004; SC-001

## CL-4 — 2026-07-13 — The rendered bundle must reproduce what Flux applies, not what Helm emits

**Asked by**: Controller (during T005 execution)
**Context**: The first gate run flagged `Deployment/loggen-loggen` for carrying container-level fields (`readOnlyRootFilesystem`, `allowPrivilegeEscalation`, `capabilities`) in its **pod-level** `securityContext`. Investigation showed the repo already knew: `observability/base/loggen/helmrelease.yaml` carries a `postRenderers[].kustomize` patch that strips exactly those fields, because chart 0.1.4 hardcodes them in the wrong place. The finding was a false positive produced by our own renderer, which ran `helm template` and ignored `spec.postRenderers`.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Renderer applies `spec.postRenderers` (kustomize patches/images) to the chart output, as helm-controller does | The bundle equals what Flux applies; both gates assert on reality | Renderer must reimplement a slice of helm-controller behaviour |
| B | Add loggen to a skip list | One line | Hides a workload from Polaris; and every future postRenderer silently diverges |
| C | Drop the postRenderer and pin/patch the chart instead | Removes the special case | Unrelated change; the postRenderer is the right fix for a broken upstream chart |

**Decision**: A — the renderer applies `spec.postRenderers`.
**Rationale**: An unfaithful bundle is worse than no bundle: it produces false positives now and could produce false negatives later (a postRenderer that *adds* something unsafe would go unaudited). Fidelity to what Flux actually applies is the renderer's entire contract. Also note the misplaced-`securityContext` case is precisely the bug class `.claude/rules/spec-constitution.md` documents — the repo's workaround is correct and must be honoured, not re-flagged.
**Decided by**: Conversation, 2026-07-13
**References**: FR-004; CL-1; SC-001

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
