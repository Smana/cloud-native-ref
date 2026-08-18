# ADR-0002: Use EKS Pod Identity over IRSA

**Status**: Accepted
**Date**: 2024-01-15
**Deciders**: Platform Team
**Related Spec**: [SPEC-0000: EKS Pod Identity Composition](../specs/completed/0000-#0-eks-pod-identity-composition.md)

---

## Context

Kubernetes workloads running in EKS need secure access to AWS services (S3, Route53, Secrets Manager, etc.). AWS provides two mechanisms for granting IAM permissions to pods:

1. **IRSA (IAM Roles for Service Accounts)**: Uses OIDC federation to allow Kubernetes service accounts to assume IAM roles
2. **EKS Pod Identity**: Native EKS feature (GA in EKS 1.24+) that directly associates IAM roles with service accounts

Both approaches eliminate the need for long-lived credentials, but have different operational characteristics.

---

## Decision Drivers

- **Operational simplicity**: Minimize infrastructure components to manage
- **Security**: Strong credential isolation and automatic rotation
- **Auditability**: Clear trail of which pods accessed which AWS resources
- **Maintainability**: Reduce complexity in IAM trust policies
- **Future-proofing**: Align with AWS's strategic direction

---

## Considered Options

### Option 1: IRSA (IAM Roles for Service Accounts)

Uses an OIDC identity provider in IAM that trusts the EKS cluster's OIDC issuer.

**Pros**:
- Mature, well-documented approach
- Works with EKS 1.14+
- Supports cross-account role assumption

**Cons**:
- Requires OIDC provider setup per cluster
- Complex trust policies with OIDC conditions
- Manual OIDC thumbprint rotation on certificate changes
- JWT token size can cause issues with many service accounts

### Option 2: EKS Pod Identity

Native EKS feature using the Pod Identity Agent and direct AWS API integration.

**Pros**:
- No OIDC provider required
- Simpler trust policies (no OIDC conditions)
- Automatic credential rotation
- Better session tagging for audit (includes pod name, namespace)
- AWS-managed, no infrastructure to maintain
- Smaller token size

**Cons**:
- Requires EKS 1.24+ (not an issue for new clusters)
- Pod Identity Agent addon must be installed
- Newer, less community documentation available

### Option 3: Long-Lived Credentials

Store AWS access keys in Kubernetes secrets.

**Pros**:
- Simple to implement
- Works anywhere

**Cons**:
- Security risk (credentials can be exfiltrated)
- No automatic rotation
- Violates security best practices
- Not considered viable

---

## Decision Outcome

**Chosen option**: "EKS Pod Identity"

**Rationale**: EKS Pod Identity provides better operational simplicity and security with fewer moving parts. Since all our clusters run EKS 1.24+, there's no compatibility concern. The native AWS integration eliminates OIDC provider management overhead and provides better audit capabilities through automatic session tagging.

---

## Consequences

### Positive

- No OIDC provider infrastructure to manage
- Simpler IAM trust policies (standard EKS service principal)
- Better audit trail with pod metadata in CloudTrail
- Automatic credential rotation handled by AWS
- Reduced token size improves performance

### Negative

- Requires Pod Identity Agent addon on each cluster
  - *Mitigation*: Installed via EKS managed addon in bootstrap
- Less community documentation than IRSA
  - *Mitigation*: AWS documentation is comprehensive
- Cannot use on EKS < 1.24
  - *Mitigation*: All clusters are 1.24+, not a constraint

### Neutral

- Migration from IRSA requires updating trust policies
- Crossplane composition abstracts the underlying mechanism

---

## Implementation Notes

- Pod Identity Agent installed as EKS managed addon
- EPI composition creates: IAM Role → IAM Policy → Pod Identity Association
- Trust policy uses `pods.eks.amazonaws.com` service principal
- All EPI resources prefixed with `xplane-` for identification

---

## References

- [AWS EKS Pod Identity Documentation](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [AWS Blog: EKS Pod Identity](https://aws.amazon.com/blogs/containers/amazon-eks-pod-identity-a-new-way-for-applications-on-eks-to-obtain-iam-credentials/)
- [IRSA vs Pod Identity Comparison](https://docs.aws.amazon.com/eks/latest/userguide/service-accounts.html)
- EPI Composition: `infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/`
