# Platform Constitution

This document defines the non-negotiable principles that govern all specifications and implementations in this platform. Every spec MUST comply with these principles.

**Related**: [Architecture Decision Records](../decisions/) | [SDD Workflow](./README.md)

---

## 1. Resource Naming Convention

All Crossplane-managed AWS and Kubernetes resources MUST use the `xplane-` prefix.

**Rationale**: Enables IAM policy scoping, resource identification, and prevents conflicts with non-Crossplane resources.

**Examples**:
- `xplane-myapp-sqlinstance` (correct)
- `myapp-sqlinstance` (incorrect - missing prefix)

**Reference**: [ADR-0002: EKS Pod Identity](../decisions/0002-eks-pod-identity-over-irsa.md)

---

## 2. KCL Composition Patterns

### 2.1 No Mutation After Creation (CRITICAL)

NEVER mutate resource dictionaries after creation. This causes duplicate resources due to [function-kcl issue #285](https://github.com/crossplane-contrib/function-kcl/issues/285).

**Correct Pattern**:
```kcl
# Inline conditionals within dictionary literals
_deployment = {
    metadata = {
        annotations = {
            "base" = "value"
            if _ready:
                "krm.kcl.dev/ready" = "True"
        }
    }
}
```

**Incorrect Pattern**:
```kcl
# Post-creation mutation - CAUSES DUPLICATES
_deployment = { metadata = { annotations = {} } }
if _ready:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"  # WRONG!
```

### 2.2 Formatting Requirements

- Run `kcl fmt` before every commit
- List comprehensions MUST be single-line
- CI enforces formatting and will fail otherwise

**Reference**: [ADR-0001: Use KCL for Compositions](../decisions/0001-use-kcl-for-crossplane-compositions.md)

---

## 3. Security Defaults

### 3.1 Zero-Trust Networking

All workloads MUST have CiliumNetworkPolicy defined. Default deny with explicit allow rules.

**Default policy structure**:
- Deny all ingress by default
- Allow only required ports from specific sources
- Allow egress to required destinations only

### 3.2 Secrets Management

- Secrets MUST be managed via External Secrets Operator
- NO hardcoded credentials in manifests, HelmReleases, or compositions
- Connection strings stored in Kubernetes Secrets, sourced from AWS Secrets Manager

### 3.3 Security Context

All pods MUST specify:
- `runAsNonRoot: true`
- `readOnlyRootFilesystem: true` (where possible)
- `allowPrivilegeEscalation: false`
- Resource limits defined

### 3.4 RBAC

- Follow least privilege principle
- Service accounts scoped to specific namespaces
- No cluster-admin bindings for workloads

---

## 4. IAM Conventions

### 4.1 EKS Pod Identity Over IRSA

Use EKS Pod Identity for all AWS access from pods. Do NOT use IRSA.

**Rationale**: Simpler trust policies, better audit trail, no OIDC management.

### 4.2 IAM Policy Scoping

- All IAM policies MUST be scoped to `xplane-*` resource names
- Crossplane controllers have NO deletion permissions for stateful services (S3, IAM, Route53)
- Use resource-level permissions, not `*` wildcards where possible

**Reference**: [ADR-0002: EKS Pod Identity](../decisions/0002-eks-pod-identity-over-irsa.md)

---

## 5. Observability Standards

### 5.1 Metrics

- VictoriaMetrics for all metrics collection
- Prometheus exposition format required
- ServiceMonitor CRDs for service discovery

### 5.2 Logging

- VictoriaLogs for centralized logging
- Structured JSON logging preferred
- LogsQL for querying (dot notation for Kubernetes labels)

### 5.3 Health Checks

All deployments MUST define:
- Liveness probe (restart unhealthy pods)
- Readiness probe (control traffic routing)
- Startup probe (for slow-starting applications)

---

## 6. Validation Requirements

### 6.1 Crossplane Compositions

Before committing composition changes:

| Tool | Target | Purpose |
|------|--------|---------|
| `kcl fmt` | No changes | Formatting compliance |
| `kcl run` | Success | Syntax validation |
| `crossplane render` | Success | End-to-end rendering |
| Polaris | Score 85+ | Security best practices |
| kube-linter | No errors | Kubernetes best practices |
| Datree | Pass | Policy enforcement |

**Validation script**: `./scripts/validate-kcl-compositions.sh`

### 6.2 Infrastructure Changes

Before applying OpenTofu changes:

| Tool | Target | Purpose |
|------|--------|---------|
| `tofu validate` | Success | Syntax validation |
| `trivy config` | No high/critical | Security scanning |
| `terramate script run preview` | Review changes | Change verification |

---

## 7. GitOps Principles

### 7.1 Single Source of Truth

All cluster state is defined in Git. Manual `kubectl apply` is prohibited for permanent changes.

### 7.2 Flux Dependency Hierarchy

Resources deploy in this order:
1. Namespaces → CRDs → Crossplane → EKS Pod Identities
2. Security (External Secrets, Cert-Manager, Kyverno)
3. Infrastructure (Cilium, DNS, Load Balancers)
4. Observability (VictoriaMetrics, Grafana)
5. Applications

### 7.3 HelmRelease Patterns

- Values in separate files, not inline
- Version pinning required (no `latest` or `*`)
- Flux remediation configured for failures

---

## 8. Documentation Requirements

### 8.1 Compositions

Every KCL composition MUST include:
- `README.md` with usage examples
- `settings-example.yaml` for local testing
- Basic and complete example claims in `examples/`

### 8.2 Specifications

Non-trivial changes require specs per [SDD workflow](./README.md).

---

## Compliance Checklist

Use this checklist when reviewing specs and implementations:

- [ ] Resource names use `xplane-*` prefix
- [ ] No KCL mutation patterns (issue #285)
- [ ] CiliumNetworkPolicy defined
- [ ] Secrets via External Secrets (no hardcoded)
- [ ] Security context enforced (non-root, read-only FS)
- [ ] IAM scoped to `xplane-*` resources
- [ ] EKS Pod Identity used (not IRSA)
- [ ] Health probes defined (liveness, readiness)
- [ ] Observability configured (metrics, logs)
- [ ] Validation tools pass (Polaris 85+, kube-linter, Datree)
- [ ] Examples provided (basic + complete)

---

## Amendments

This constitution may be amended through the ADR process. Major principle changes require team consensus and documentation in a new ADR.

**Version**: 1.0
**Last Updated**: 2026-01-06
