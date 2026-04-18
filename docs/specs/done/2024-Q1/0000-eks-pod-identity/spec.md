# Spec: EKS Pod Identity Composition

**ID**: SPEC-0000
**Issue**: N/A (foundational composition, predates SDD workflow)
**Status**: done
**Type**: composition
**Created**: 2024-01-15
**Last updated**: 2026-04-18 (migrated to 4-artifact structure)

> Migrated from a single-file legacy spec at `docs/specs/done/0000-#0-eks-pod-identity-composition.md`. Original content split into spec.md / plan.md / clarifications.md / SUMMARY.md without alteration of meaning. Tasks live inside `plan.md`.

---

## Summary

A Crossplane composition that provides secure AWS IAM access for Kubernetes pods using EKS Pod Identity, eliminating the need for long-lived credentials.

---

## Problem

Kubernetes workloads in EKS clusters need to access AWS services (S3, Route53, Secrets Manager, etc.) securely. Traditional approaches require either:

- Long-lived IAM credentials stored as Kubernetes secrets (insecure), or
- Complex IRSA (IAM Roles for Service Accounts) setup with OIDC providers.

Platform users need a simple, declarative way to grant AWS permissions to their service accounts.

---

## User Stories

### US-1: Grant AWS Access to Service Account (Priority: P1)

As a **platform user**, I want to grant my application's service account access to specific AWS resources, so that my pods can securely interact with AWS services without managing credentials.

**Why this priority**: Core security requirement for any AWS-integrated workload.

**Acceptance Scenarios**:
1. **Given** an EPI resource with a policy document, **When** the composition reconciles, **Then** an IAM role with the specified permissions is created.
2. **Given** pods using the target service account, **When** they call AWS APIs, **Then** they receive temporary credentials automatically.

### US-2: Multi-Cluster Deployment (Priority: P2)

As a **platform operator**, I want to associate a single IAM role with service accounts across multiple EKS clusters, so that I can manage permissions centrally.

**Acceptance Scenarios**:
1. **Given** an EPI with multiple clusters defined, **When** reconciled, **Then** Pod Identity Associations are created in each cluster.

---

## Requirements

### Functional

- **FR-001**: System MUST create an IAM role with EKS Pod Identity trust policy.
- **FR-002**: System MUST create an IAM policy from user-provided JSON document.
- **FR-003**: System MUST create Pod Identity Association linking role to service account.
- **FR-004**: System SHOULD support attaching additional AWS managed policies.
- **FR-005**: System SHOULD support multi-cluster associations from single resource.

### Non-Goals

- IRSA (IAM Roles for Service Accounts) support — replaced by Pod Identity.
- Cross-account IAM role assumption (future enhancement).
- Fine-grained session policies.

---

## Success Criteria

- **SC-001**: Pods can call AWS APIs without explicit credential configuration.
- **SC-002**: IAM roles are automatically cleaned up when EPI is deleted.
- **SC-003**: Credentials rotate automatically (no manual intervention).

---

## References

- Plan: [plan.md](plan.md)
- Clarifications: [clarifications.md](clarifications.md)
- Summary (post-merge): [SUMMARY.md](SUMMARY.md)
- Constitution: [docs/specs/constitution.md](../../../constitution.md)
- Related ADR: [ADR-0002: EKS Pod Identity over IRSA](../../../../decisions/0002-eks-pod-identity-over-irsa.md)
- KCL Module: `infrastructure/base/crossplane/configuration/kcl/eks-pod-identity/`
- Usage: `security/base/epis/`
- AWS Docs: [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
