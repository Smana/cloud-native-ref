# Plan: Remove Dagger from the opinionated platform stack

**Spec**: [SPEC-009](spec.md)
**Status**: draft (plan only — implementation deferred by the user, run later)
**Last updated**: 2026-07-15

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

A removal, not a build. Three independent surfaces, each removable on its own, so this can
land as one PR or a small sequence. No composition, no KCL, no new resources.

### Teardown surfaces

| Surface | What | Action | Risk |
|---|---|---|---|
| CI — Terraform | `dagger call pre-commit-tf` job in `ci.yaml` | Replace with the native `pre-commit-terraform` hooks (already in `.pre-commit-config.yaml`) or run them in the existing "Pre-commit checks" job | Low — must confirm the native hooks run in CI, not just locally |
| CI — kubeconform | `dagger call kubeconform` (×2) in `ci.yaml` | **None here** — SPEC-007 / #1593 already replaces these with `validate-manifests.sh` | None (owned by #1593) |
| In-cluster engine | `tooling/base/dagger-engine/` (Deployment/Service/ConfigMap/PDB/NetworkPolicy) + its commented line in `tooling/mycluster-0/kustomization.yaml` | Delete the directory and the dead reference | None — dormant, never reconciled (reference is commented out) |
| GHA runners | `tooling/base/gha-runners/dagger-scale-set-helmrelease.yaml` | **Keep the runner pool (CL-1).** Strip only dead Dagger-specific config; rename the scale set to a neutral name if `dagger-` no longer fits | Medium — must not interrupt CI that runs on self-hosted runners |
| Docs | `docs/ci-workflows.md`, blog link | Update to reflect no Dagger; decide on a minimal teaching example (open question) | None |

### Dependencies / sequencing

- **Depends on #1593** for the kubeconform-Dagger removal. Land SPEC-009 after #1593 merges,
  or rebase this branch on it — otherwise the two edit `ci.yaml`'s validation jobs in
  conflicting ways. (Open question in spec; resolve at implementation time.)

### Alternatives considered

Keep Dagger but trim it to just the CI step — rejected: the step is the redundant part, and
keeping the dormant engine manifests + a Dagger-named runner set is the maintenance/clarity
cost we want gone. Full removal (per CL-1, minus the runners) is cleaner.

---

## Implementation Notes

- **Confirm before deleting the CI step (T001):** verify the native `terraform_fmt` /
  `terraform_validate` / `terraform_tflint` hooks actually execute in CI (the "Pre-commit
  checks 🛃" job), not only via local `pre-commit`. If CI skips them, wire them on before
  removing the Dagger job — never drop coverage.
- **Runners are kept (CL-1):** treat the runner scale set as a rename/cleanup, not a delete.
  A pool the whole CI depends on must not go down.
- **The engine is dead code:** its kustomization reference is already commented out, so
  deleting `tooling/base/dagger-engine/` changes nothing at runtime — safe.

---

## Tasks

> Each task has a stable ID. Committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)). **Implementation deferred — do not start until the user says go.**

### Phase 1: Confirm coverage (no deletions yet)

- [ ] **T001**: Prove the native `pre-commit-terraform` hooks run in CI and cover fmt +
  validate + tflint for every OpenTofu stack the Dagger step covered. Evidence: a CI run
  (or `pre-commit run --all-files`) showing the three hooks executing and passing.
- [ ] **T002**: Audit `runs-on:` across `.github/workflows/**` for
  `dagger-gha-runner-scale-set`. Record which jobs (if any) use it — drives the T005 rename.

### Phase 2: Remove (after #1593 has merged / been rebased in)

- [ ] **T003**: Delete the `dagger call pre-commit-tf` job/step from `ci.yaml`; ensure TF
  validation still runs via the native hooks (from T001).
- [ ] **T004**: Delete `tooling/base/dagger-engine/` and its commented reference in
  `tooling/mycluster-0/kustomization.yaml`. Remove any `.polaris.yaml` / kustomization
  entry that names it.
- [ ] **T005**: Strip Dagger-specific config from `gha-runners/` and, if the `dagger-`
  scale-set name no longer fits, rename to a neutral self-hosted scale set **without pool
  downtime** (runners kept — CL-1). Migrate any jobs found in T002 first.
- [ ] **T006**: Update `docs/ci-workflows.md` and any remaining doc references so nothing
  points at Dagger. Resolve the "minimal teaching example" open question.

### Phase 3: Verify

- [ ] **T007**: `grep -rniE 'dagger' .github/ tooling/ mise.toml` → no operational
  reference (SC-001).
- [ ] **T008**: CI green on the PR — OpenTofu validation passes via native pre-commit; the
  Kubernetes-validation job (validate-manifests.sh) unaffected (SC-002).
- [ ] **T009**: A CI job runs on the self-hosted runner pool and succeeds; no Dagger
  engine/socket/label config remains on it (SC-004).

### Deviations from plan

<!-- Append as implementation surprises show up. -->

---

## Review Checklist

Complete before implementation begins. Items that don't apply to a removal are marked N/A.

### Project Manager

- [ ] Problem statement in spec.md is clear and specific
- [ ] Scope is well-defined (goals AND non-goals) — incl. CL-1 (runners kept)
- [ ] Success criteria are measurable and falsifiable
- [ ] Sequencing vs #1593 decided

### Platform Engineer

- [ ] T001 proves the native pre-commit hooks cover what the Dagger step did (no lost coverage)
- [ ] Engine deletion confirmed as dead code (kustomization ref commented out)
- [ ] Runner rename/cleanup causes no pool downtime
- [ ] N/A: composition patterns / `xplane-*` naming / KCL mutation — no composition here

### Security & Compliance

- [ ] No new attack surface (this only removes); the dagger-engine NetworkPolicy going away
  is fine because the workload is gone with it
- [ ] Self-hosted runner change does not widen runner permissions
- [ ] N/A: External Secrets / IAM scoping — none introduced

### SRE

- [ ] CI stays green throughout (validation coverage preserved, not just "reconciled")
- [ ] Rollback is a git revert (removal PR); no data/state involved
- [ ] N/A: liveness/readiness probes, VictoriaMetrics/Logs wiring — nothing deployed

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Related: SPEC-007 / PR #1593 (removes the kubeconform Dagger functions)
