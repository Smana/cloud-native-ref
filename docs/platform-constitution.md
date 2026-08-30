---
title: Platform Constitution
weight: 60
description: The non-negotiable rules every design, composition and manifest is checked against.
lastVerified: 2026-08-20
---

# Platform Constitution

This document defines the non-negotiable principles that govern all designs and implementations in this platform. Every design MUST comply with these principles.

**Related**: [Architecture Decision Records](https://cnref.ogenki.io/docs/decisions/) | [Development workflow](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md#development-workflow-superpowers)

---

## 1. Resource Naming Convention

All Crossplane-managed AWS and Kubernetes resources MUST use the `xplane-` prefix.

**Rationale**: Enables IAM policy scoping, resource identification, and prevents conflicts with non-Crossplane resources.

**Examples**:
- `xplane-myapp-sqlinstance` (correct)
- `myapp-sqlinstance` (incorrect - missing prefix)

**Reference**: [ADR-0002: EKS Pod Identity](https://cnref.ogenki.io/docs/decisions/0002-eks-pod-identity-over-irsa/)

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

**Reference**: [ADR-0001: Use KCL for Compositions](https://cnref.ogenki.io/docs/decisions/0001-use-kcl-for-crossplane-compositions/)

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

**Reference**: [ADR-0002: EKS Pod Identity](https://cnref.ogenki.io/docs/decisions/0002-eks-pod-identity-over-irsa/)

---

## 5. Observability Standards

### 5.1 Metrics

- VictoriaMetrics for all metrics collection
- Prometheus exposition format required
- `VMServiceScrape` CRDs for service discovery (the VictoriaMetrics operator also converts
  `ServiceMonitor`/`PrometheusRule` objects a chart ships natively, so either is acceptable
  from an upstream chart's own values)

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

Compositions are not edited in this repo — they live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration). Before
committing a composition change, in that repo:

| Tool | Target | Purpose |
|------|--------|---------|
| `kcl fmt` | No changes | Formatting compliance |
| `kcl test` | Success | Unit tests against golden fixtures |
| XRD schema check | Success | Composition output matches the XRD |

**Validation**: `task check` in that repo runs all three, plus render-equivalence against golden
fixtures. This repo only pins the released version, in
`infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` (and the GCP
equivalent) — it does not re-run KCL validation itself.

### 6.2 Rendered Manifests

Every claim and manifest in this repo — including ones the pinned Composition above renders — is
gated before merge:

| Tool | Target | Purpose |
|------|--------|---------|
| `flux schema validate` | Success, `skipMissingSchemas: false` | Structure + CEL, against the repo's XRDs and the Flux/CNCF catalogs |
| `polaris audit --set-exit-code-on-danger` | No danger-level findings | Workload best practices |

**Validation**: `./scripts/validate-manifests.sh`, the single entry point CI runs. It renders the
repository the way Flux does — every Kustomize overlay and `HelmRelease` — then applies both
gates to the rendered bundle.

### 6.3 Infrastructure Changes

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

Broadly, resources deploy in this order:

1. Namespaces → CRDs → Crossplane → EKS Pod Identities
2. Security (External Secrets, Cert-Manager, Kyverno)
3. Infrastructure (Cilium, DNS, Load Balancers)
4. Observability (VictoriaMetrics, Grafana)
5. Applications

**This is a simplified model, not the dependency graph.** It states the
principle — foundations before the things that build on them — and is the right
level for deciding roughly where a new component belongs. It is *not* accurate
enough to copy a `dependsOn` from. The real graph is wider than a chain: the
Crossplane stage is three sequential Kustomizations, Karpenter sits outside them,
`infrastructure` depends on `karpenter` and `eks-pod-identities` rather than on
`security`, and several `flux/*` self-management Kustomizations run in parallel.

**Before setting `dependsOn` on anything, read the real graph**, derived from the
manifests and kept current:
[Platform → GitOps](https://cnref.ogenki.io/docs/platform/gitops/). When the two
disagree, `clusters/aws-0/` wins.

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

### 8.2 Design documents

Non-trivial changes are designed before they are built, using the
[Superpowers](https://github.com/obra/superpowers) workflow (see `CLAUDE.md` →
*Development Workflow*).

| Artifact | Path | Produced by |
|----------|------|-------------|
| Design | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | `superpowers:brainstorming` |
| Plan | `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` | `superpowers:writing-plans` |
| Verification | `docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md` | `/verify-spec`, post-merge |

**Decisions are durable**: a design records the options considered, the decision, and the
rationale — not just the outcome. Never leave a `[NEEDS CLARIFICATION]` marker in an approved
design; resolve it and write down why.

Specs produced by the retired in-house SDD workflow (2026-Q1 → 2026-Q3) are archived read-only
under [`docs/specs/`](https://github.com/Smana/cloud-native-ref/tree/main/docs/specs).

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
- [ ] Validation tools pass (`flux schema validate`, `polaris audit --set-exit-code-on-danger`, and `task check` in `Smana/crossplane-configuration` for any composition change)
- [ ] Examples provided (basic + complete)
- [ ] Design doc committed under `docs/superpowers/specs/` and linked from the PR
- [ ] No `[NEEDS CLARIFICATION]` markers left in the approved design
- [ ] Design written and approved before implementation
- [ ] ADR written for any technology chosen over a named alternative

---

## Amendments

This constitution may be amended through the ADR process. Major principle changes require team consensus and documentation in a new ADR.

**Version**: 1.0
**Last Updated**: 2026-01-06
