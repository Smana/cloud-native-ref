# Spec: Remove Dagger from the opinionated platform stack

**ID**: SPEC-009
**Issue**: [#1595](https://github.com/Smana/cloud-native-ref/issues/1595)
**Status**: draft
**Type**: platform
**Created**: 2026-07-15
**Last updated**: 2026-07-15

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Retire Dagger from the platform. Its footprint has shrunk to the point of being low-ROI
and partly redundant, and the parts that remain cost more to maintain and explain — in a
*reference* stack — than they return.

---

## Problem

Dagger earns its place when a repo runs rich, reproducible, containerized pipeline steps
shared between laptop and CI. This repo no longer does. Its remaining touchpoints:

- **CI (`.github/workflows/ci.yaml`)**
  - `dagger call kubeconform` (×2) — **already being removed by SPEC-007 / PR #1593**,
    which replaces it with `./scripts/validate-manifests.sh` (flux schema + polaris).
  - `dagger call pre-commit-tf` (the "Validate Opentofu configuration" job) — runs
    Terraform fmt/validate/tflint, which the native `antonbabenko/pre-commit-terraform`
    hooks in `.pre-commit-config.yaml` already cover. Redundant.
- **In-cluster engine (`tooling/base/dagger-engine/`)** — Deployment + Service +
  ConfigMap + PDB + NetworkPolicy. **Dormant:** the reference in
  `tooling/mycluster-0/kustomization.yaml` is commented out, so it is not reconciled onto
  the cluster. Removal here is deleting dead manifests, not tearing down a running engine.
- **Dagger GHA runner scale set (`tooling/base/gha-runners/dagger-scale-set-helmrelease.yaml`)**
  — a dedicated `dagger-gha-runner-scale-set`, separate from the default runner set.
  Whether any workflow still targets it (`runs-on: dagger-gha-runner-scale-set`) must be
  confirmed during planning.
- **Docs** — `docs/ci-workflows.md` (SPEC-007 already rewrote its kubeconform mentions);
  the blog's [Dagger intro post](https://blog.ogenki.io/post/dagger-intro/) is linked from
  the repo.

The rationale is **low ROI and redundancy**, explicitly *not* trendiness and *not* "AI
replaces it" — AI does not do what Dagger does (reproducible containerized builds); that
would be a category error, and is called out here so the decision is made for the right
reason.

**Why now?** SPEC-007 already moves the largest Dagger consumer (manifest validation) onto
a plain script. Finishing the job while that context is fresh avoids leaving the stack in a
half-on-Dagger state.

---

## Requirements

### Functional

- **FR-001**: CI MUST validate OpenTofu without Dagger — the native
  `pre-commit-terraform` hooks (fmt / validate / tflint) MUST cover what
  `dagger call pre-commit-tf` did, and the Dagger step MUST be removed from `ci.yaml`.
- **FR-002**: All Dagger `uses:`/`call` steps MUST be gone from `.github/workflows/`
  (the kubeconform ones land via #1593; this spec owns whatever remains after it merges).
- **FR-003**: The dormant `tooling/base/dagger-engine/` manifests and their commented
  reference MUST be deleted (dead code).
- **FR-004**: The self-hosted GitHub Actions runners are KEPT (CL-1). Only Dagger-*specific*
  configuration on the runner scale set — a dagger engine sidecar/socket, dagger labels —
  MUST be removed if it becomes dead once Dagger is gone. The runner pool itself stays and,
  if the `dagger-`-named scale set no longer makes sense, MAY be renamed to a neutral
  self-hosted scale set (no pool downtime).
- **FR-005**: Dagger references in `docs/` MUST be updated or removed so no guidance points
  at a tool the repo no longer uses.
- **FR-006**: `./scripts/validate-manifests.sh` MUST stay green, and CI MUST stay green,
  after removal.

### Non-Goals

- Replacing Dagger with another pipeline-as-code tool. The native pre-commit hooks and
  plain scripts are the replacement.
- Removing the blog post or its concepts — a decision on keeping a *minimal teaching
  example* is an open question, not a mandate.
- Any change to the SPEC-007 validation pipeline itself (that is #1593's contract).
- Removing the self-hosted GitHub Actions runners — they stay regardless of Dagger (CL-1).

---

## Success Criteria

- **SC-001**: `grep -rniE 'dagger' .github/ tooling/ mise.toml` returns no operational
  reference (only intentional historical/doc mentions, if any are deliberately kept).
- **SC-002**: CI is green on a PR with the changes — the OpenTofu validation job passes
  via native pre-commit, and the Kubernetes-validation job (validate-manifests.sh) is
  unaffected.
- **SC-003**: `kubectl get all -n <dagger-engine-ns>` finds nothing (confirming the engine
  was never live) and the manifests are gone from the tree.
- **SC-004**: The self-hosted runner pool still services CI (a job runs on it and
  succeeds); no Dagger-specific engine/socket/label config remains on it.

---

## Open questions

- [ ] [NEEDS CLARIFICATION: Keep a minimal Dagger example somewhere for the blog's teaching
  story, or remove cleanly and let the blog post stand on its own history?]
- [ ] [NEEDS CLARIFICATION: Sequence vs #1593 — land this only after SPEC-007 merges (so the
  kubeconform-Dagger removal is already in), or rebase this branch on #1593?]

**Resolved:**

- CL-1 — Self-hosted GitHub Actions runners are KEPT; only dead Dagger-specific runner config is cleaned up.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Related: SPEC-007 (PR #1593) — replaces the kubeconform Dagger functions with
  `validate-manifests.sh`; this spec removes what is left.
