# Process Rules — verification and debugging

Auto-loaded when editing files under `docs/superpowers/**`, `infrastructure/**`, `security/**`, `observability/**`, `tooling/**`, `opentofu/**`, `clusters/**`, or `flux/**`. The generic methodology lives in the superpowers plugin (`superpowers:verification-before-completion`, `superpowers:systematic-debugging`); this file captures the repo-specific deltas.

## Verification before completion

No "done / fixed / passing / ready" claim without a fresh command run in the same response. Previous runs don't count — cluster and file state drift.

Before claiming status: identify the command, run it fresh, cite the output inline (numbers or exit code, not prose).

### Repo-specific evidence table

| Claim | Evidence (fresh, this message) |
|-------|--------------------------------|
| Manifests valid | `./scripts/validate-manifests.sh` → exit 0, and the report shows `Invalid: 0, Skipped: 0` |
| KCL composition valid | `./scripts/validate-kcl-compositions.sh` → exit 0 |
| Design ready | Design doc committed under `docs/superpowers/specs/`, no `[NEEDS CLARIFICATION]` markers left |
| Success criteria met (post-merge) | `/verify-spec <design-doc>` against live cluster |
| Flux reconciled | `flux get kustomizations` / `helmreleases` → `Ready=True` |
| Crossplane XR ready | `kubectl get <xr>` → `Synced=True` and `Ready=True` |
| Policy change works | `hubble observe --verdict DROPPED` matches intent |
| Configuration change took effect | Observable difference (rendered manifest, log line, API response) — not just "reconciled" |

**`Skipped: 0` is part of the claim, not decoration.** A resource with no schema is not validated;
it is ignored. Reporting "validation passed" while resources were skipped is the failure mode
SPEC-007 was written to remove — kubeconform ran with `-ignore-missing-schemas` and every
`cloud.ogenki.io` claim in the repo went unchecked for the life of the project.

Generic commands (`kcl fmt`, `trivy config`, `tofu plan`) are already listed in [`CLAUDE.md`](../../CLAUDE.md) under *Validation Commands* and the per-domain rules (`opentofu.md`, `kcl-crossplane.md`).

## Systematic debugging

No fixes without root-cause investigation. Symptom fixes mask the real problem and create new bugs.

Four phases, in order:

1. **Investigate** — read the error exactly, reproduce, check recent commits / Renovate PRs / Flux lastHandled timestamps, gather evidence at each layer (use `/gitops-cluster-debug` for the Flux → Kubernetes → Crossplane chain; use the `victorialogs` / `victoriametrics` MCPs for log/metric scale; use `hubble observe` for network).
2. **Pattern** — find a working analogue (sibling composition, prior commit, reference ADR). List every difference — no detail is too small.
3. **Hypothesize** — one stated theory, smallest possible test, one variable. Worked → step 4. Didn't work → new hypothesis, do not pile fixes.
4. **Fix** — single change at the root cause. Reproduce as a test when feasible (`main_test.k` for KCL, `./scripts/validate-manifests.sh` for manifests). Verify with the evidence table above.

After three failed fixes, stop — the pattern is probably wrong, not fix #4. Raise it.

## Rationalizations — common and wrong

| Excuse | Reality |
|--------|---------|
| "Should work now" / "I'm confident" | Run the command; confidence isn't evidence |
| "Agent / subagent said success" | Check `git diff` yourself; re-run the validator |
| "Linter passed" | Linter ≠ validator ≠ cluster reality |
| "Quick fix first, investigate later" | The first fix sets the pattern |
| "Multiple fixes at once saves time" | Can't isolate what worked; creates new bugs |
| "Issue is simple, skip the process" | Simple bugs have root causes too, and the process is fast for them |
| "One more attempt" (after three) | Three failed fixes ⇒ wrong architecture, not fix #4 |

## When to apply

Before: `/commit`, `/create-pr`, marking a T-id `[x]`, closing an issue, saying "you can merge" — run the evidence command and cite the result.

During: any failing HelmRelease / Kustomization / XR / pod, `tofu` drift, CI failures, "it worked yesterday" — start from phase 1.
