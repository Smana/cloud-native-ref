# Plan: EKS Pod Identity Composition

**Spec**: [SPEC-0000](spec.md)
**Status**: done
**Last updated**: 2026-04-18 (migrated to 3-artifact structure)

---

## Design

### API Design (XRD)

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: EPI
metadata:
  name: xplane-my-app
  namespace: apps
spec:
  # Required: Target service account
  serviceAccount:
    name: my-app
    namespace: apps

  # Required: EKS clusters to associate with
  clusters:
    - name: mycluster-0
      region: eu-west-3

  # Required: IAM policy document (JSON)
  policyDocument: |
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject"],
        "Resource": "arn:aws:s3:::my-bucket/*"
      }]
    }

  # Optional: Additional managed policies
  additionalPolicyArns:
    - name: cloudwatch-readonly
      arn: arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| IAM Role | Always | Trust policy for `pods.eks.amazonaws.com` |
| IAM Policy | Always | User-defined permissions |
| Role Policy Attachment | Always | Links custom policy to role |
| Pod Identity Association | Per cluster | Links role to service account |
| Additional Policy Attachments | If `additionalPolicyArns` | AWS managed policies |

### Key Entities

- **IAM Role**: `{name}-iam-role` — assumable by EKS Pod Identity service.
- **IAM Policy**: `{name}-iam-policy` — custom permissions from `policyDocument`.
- **Pod Identity Association**: links the IAM role to a specific service account in a cluster.

### Dependencies

- [x] EKS cluster with Pod Identity agent installed
- [x] Crossplane AWS provider configured
- [x] Target namespace and service account exist

### Alternatives considered

IRSA (IAM Roles for Service Accounts) was the previous approach but requires per-cluster OIDC configuration and longer-lived JWTs. EKS Pod Identity simplifies the trust model with shorter-lived tokens scoped per cluster. See ADR-0002.

---

## Implementation Notes

### KCL Module Structure

```
infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/
├── main.k              # Composition logic
├── kcl.mod             # Module: v0.2.2
├── kcl.mod.lock
├── settings-example.yaml
└── README.md
```

### Key Implementation Notes

1. **Trust Policy**: automatically configured for EKS Pod Identity service principal.
2. **Resource Linking**: uses `matchControllerRef: True` for automatic association.
3. **Multi-Cluster**: iterates over `spec.clusters` to create associations.

### Validation path

- [x] `kcl fmt` passes
- [x] `kcl run` with `settings-example.yaml` succeeds
- [x] `crossplane render` with example succeeds
- [x] Polaris audit score ≥ 85
- [x] kube-linter passes

---

## Tasks

> Reconstructed retrospectively from the original Validation/Testing sections of the legacy single-file spec; all checked since the composition shipped.

### Phase 1: Implementation

- [x] **T001**: Author KCL module at `infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/main.k`
- [x] **T002**: Define XRD with `serviceAccount`, `clusters`, `policyDocument`, optional `additionalPolicyArns` (FR-004, FR-005)
- [x] **T003**: Generate IAM role with Pod Identity trust policy (FR-001)
- [x] **T004**: Generate IAM policy from user-provided JSON (FR-002)
- [x] **T005**: Generate `PodIdentityAssociation` per cluster (FR-003)

### Phase 2: Validation

- [x] **T006**: `kcl fmt` passes
- [x] **T007**: `kcl run -Y settings-example.yaml` renders
- [x] **T008**: `crossplane render` with basic example succeeds
- [x] **T009**: Polaris audit score ≥ 85
- [x] **T010**: kube-linter passes

### Phase 3: Documentation & Examples

- [x] **T011**: `README.md` describing API and usage
- [x] **T012**: `settings-example.yaml`
- [x] **T013**: Basic example in `examples/epi.yaml` for `cert-manager`
- [x] **T014**: Multi-cluster example
- [x] **T015**: Real consumers wired in `security/base/epis/*.yaml`

### Phase 4: ADR

- [x] **T016**: Author ADR-0002 (`docs/decisions/0002-eks-pod-identity-over-irsa.md`)

### Deviations from plan

_None recorded for this retrospective migration._

---

## Review Checklist

### Project Manager

- [x] Problem statement is clear (secure AWS access without credentials)
- [x] User stories capture real needs
- [x] Acceptance criteria are measurable
- [x] Scope is well-defined

### Platform Engineer

- [x] XRD follows progressive complexity principle
- [x] Consistent with existing composition patterns
- [x] Resource naming follows `xplane-*` convention
- [x] KCL avoids mutation pattern (function-kcl #285)
- [x] Example provided

### Security & Compliance

- [x] Least-privilege IAM (user defines minimal permissions)
- [x] No long-lived credentials
- [x] Automatic credential rotation via Pod Identity
- [x] Audit trail via AWS CloudTrail

### SRE

- [x] Resources observable via `kubectl get epi`
- [x] Status fields expose role/policy ARNs
- [x] Automatic cleanup on deletion

---

## References

- Spec: [spec.md](spec.md)
- Clarifications: [clarifications.md](clarifications.md)
- Summary: [SUMMARY.md](SUMMARY.md)
- ADR: [ADR-0002: EKS Pod Identity over IRSA](../../../../decisions/0002-eks-pod-identity-over-irsa.md)
