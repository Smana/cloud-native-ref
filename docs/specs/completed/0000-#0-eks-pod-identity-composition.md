# Spec: EKS Pod Identity Composition

**Spec ID**: SPEC-0000
**GitHub Issue**: N/A (foundational composition)
**Status**: Implemented
**Author**: Platform Team
**Created**: 2024-01-15
**Last Updated**: 2024-01-15

---

## Summary

A Crossplane composition that provides secure AWS IAM access for Kubernetes pods using EKS Pod Identity, eliminating the need for long-lived credentials.

---

## Motivation

### Problem Statement

Kubernetes workloads in EKS clusters need to access AWS services (S3, Route53, Secrets Manager, etc.) securely. Traditional approaches require either:
- Long-lived IAM credentials stored as Kubernetes secrets (insecure)
- Complex IRSA (IAM Roles for Service Accounts) setup with OIDC providers

Platform users need a simple, declarative way to grant AWS permissions to their service accounts.

### User Stories & Acceptance Scenarios

#### User Story 1 - Grant AWS Access to Service Account (Priority: P1)

As a **platform user**, I want to grant my application's service account access to specific AWS resources, so that my pods can securely interact with AWS services without managing credentials.

**Why this priority**: Core security requirement for any AWS-integrated workload.

**Acceptance Scenarios**:
1. **Given** an EPI resource with a policy document, **When** the composition reconciles, **Then** an IAM role with the specified permissions is created
2. **Given** pods using the target service account, **When** they call AWS APIs, **Then** they receive temporary credentials automatically

#### User Story 2 - Multi-Cluster Deployment (Priority: P2)

As a **platform operator**, I want to associate a single IAM role with service accounts across multiple EKS clusters, so that I can manage permissions centrally.

**Acceptance Scenarios**:
1. **Given** an EPI with multiple clusters defined, **When** reconciled, **Then** Pod Identity Associations are created in each cluster

### Functional Requirements

- **FR-001**: System MUST create an IAM role with EKS Pod Identity trust policy
- **FR-002**: System MUST create an IAM policy from user-provided JSON document
- **FR-003**: System MUST create Pod Identity Association linking role to service account
- **FR-004**: System SHOULD support attaching additional AWS managed policies
- **FR-005**: System SHOULD support multi-cluster associations from single resource

### Success Criteria

- **SC-001**: Pods can call AWS APIs without explicit credential configuration
- **SC-002**: IAM roles are automatically cleaned up when EPI is deleted
- **SC-003**: Credentials rotate automatically (no manual intervention)

### Non-Goals

- IRSA (IAM Roles for Service Accounts) support - replaced by Pod Identity
- Cross-account IAM role assumption (future enhancement)
- Fine-grained session policies

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

### Generated Resources

| Resource | Condition | Notes |
|----------|-----------|-------|
| IAM Role | Always | Trust policy for `pods.eks.amazonaws.com` |
| IAM Policy | Always | User-defined permissions |
| Role Policy Attachment | Always | Links custom policy to role |
| Pod Identity Association | Per cluster | Links role to service account |
| Additional Policy Attachments | If `additionalPolicyArns` | AWS managed policies |

### Key Entities

- **IAM Role**: `{name}-iam-role` - Assumable by EKS Pod Identity service
- **IAM Policy**: `{name}-iam-policy` - Custom permissions from `policyDocument`
- **Pod Identity Association**: Links the IAM role to a specific service account in a cluster

### Dependencies

- [x] EKS cluster with Pod Identity agent installed
- [x] Crossplane AWS provider configured
- [x] Target namespace and service account exist

---

## Implementation

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

1. **Trust Policy**: Automatically configured for EKS Pod Identity service principal
2. **Resource Linking**: Uses `matchControllerRef: True` for automatic association
3. **Multi-Cluster**: Iterates over `spec.clusters` to create associations

### Example Usage

**Basic Example** (`examples/epi.yaml`):
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: EPI
metadata:
  name: xplane-cert-manager
  namespace: security
spec:
  serviceAccount:
    name: cert-manager
    namespace: cert-manager
  clusters:
    - name: mycluster-0
      region: eu-west-3
  policyDocument: |
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Action": [
          "route53:GetChange",
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets"
        ],
        "Resource": "*"
      }]
    }
```

---

## Validation

### Pre-Commit Checklist

- [x] `kcl fmt` passes
- [x] `kcl run` with settings-example.yaml succeeds
- [x] `crossplane render` with example succeeds
- [x] Polaris audit score >= 85
- [x] kube-linter passes

### Testing Strategy

- [x] Basic example renders IAM role, policy, and association
- [x] Multi-cluster example creates multiple associations
- [x] Additional policies are attached correctly

---

## Review Checklist

### Project Manager (PM)

- [x] Problem statement is clear (secure AWS access without credentials)
- [x] User stories capture real needs
- [x] Acceptance criteria are measurable
- [x] Scope is well-defined

### Platform Engineer

- [x] XRD follows progressive complexity principle
- [x] Consistent with existing composition patterns
- [x] Resource naming follows `xplane-*` convention
- [x] KCL avoids mutation pattern (issue #285)
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

## Real-World Usage

Currently deployed for:

| Service | Namespace | AWS Permissions |
|---------|-----------|-----------------|
| cert-manager | cert-manager | Route53 DNS challenges |
| external-dns | kube-system | Route53 record management |
| external-secrets | security | Secrets Manager access |
| harbor | tooling | S3 bucket access |
| victoriametrics | observability | EC2 instance discovery |

---

## References

- Related ADR: [ADR-0002: EKS Pod Identity over IRSA](../../decisions/0002-eks-pod-identity-over-irsa.md)
- KCL Module: `infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/`
- Usage: `security/base/epis/`
- AWS Docs: [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
