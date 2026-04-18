# Tasks: EKS Pod Identity Composition

**Spec**: [SPEC-0000](spec.md)
**Plan**: [plan.md](plan.md)
**Last updated**: 2026-04-18 (retrospective migration)

> This spec was implemented before the SDD task-tracking convention. Tasks below are reconstructed from the original Validation/Testing sections of the legacy single-file spec; all are checked since the composition shipped.

---

## Phase 1: Implementation

- [x] **T001**: Author KCL module at `infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/main.k`
- [x] **T002**: Define XRD with `serviceAccount`, `clusters`, `policyDocument`, optional `additionalPolicyArns`
- [x] **T003**: Generate IAM role with Pod Identity trust policy
- [x] **T004**: Generate IAM policy from user-provided JSON
- [x] **T005**: Generate `PodIdentityAssociation` per cluster

## Phase 2: Validation

- [x] **T006**: `kcl fmt` passes
- [x] **T007**: `kcl run -Y settings-example.yaml` renders
- [x] **T008**: `crossplane render` with basic example succeeds
- [x] **T009**: Polaris audit score ≥ 85
- [x] **T010**: kube-linter passes

## Phase 3: Documentation & Examples

- [x] **T011**: `README.md` describing API and usage
- [x] **T012**: `settings-example.yaml`
- [x] **T013**: Basic example in `examples/epi.yaml` for `cert-manager`
- [x] **T014**: Multi-cluster example
- [x] **T015**: Real consumers wired in `security/base/epis/*.yaml`

## Phase 4: ADR

- [x] **T016**: Author ADR-0002 (`docs/decisions/0002-eks-pod-identity-over-irsa.md`)

---

## Deviations from plan

_None recorded for this retrospective migration._
