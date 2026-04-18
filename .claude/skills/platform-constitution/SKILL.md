---
name: platform-constitution
description: Platform-wide non-negotiable rules for this cloud-native-ref repo — resource naming (xplane-*), KCL patterns (no mutation), security defaults (zero-trust, External Secrets, non-root), IAM (EKS Pod Identity over IRSA), observability (VictoriaMetrics / VictoriaLogs), GitOps (Flux dependency hierarchy). Auto-loads when Claude is designing compositions, specs, security policies, or reviewing infrastructure changes.
when_to_use: |
  Auto-load during design discussions, spec review, code review of
  infrastructure/crossplane/security code, or any time Claude is about
  to propose a new resource, IAM policy, network policy, KCL composition,
  or GitOps manifest. Not user-invocable.
user-invocable: false
paths: docs/specs/**, infrastructure/**, security/**, observability/**, tooling/**
allowed-tools: Read
---

# Platform Constitution (reference knowledge)

Non-negotiable rules. Every composition, spec, PR, and review must comply. When in doubt, **match the existing pattern** (see canonical compositions: `eks-pod-identity`, `app`, `cloudnativepg`, `sqlinstance`). Deviations require an ADR.

## Resource naming

- **All Crossplane-managed resources** use the `xplane-*` prefix (e.g., `xplane-harbor`, `xplane-cert-manager-role`). This prefix is load-bearing for IAM scoping.
- Claims and XRs: `xplane-<application>-<purpose>`.
- Do not rename existing resources casually — Crossplane treats rename as delete-create.

## KCL composition patterns

- **Never mutate a dict after creation** — causes duplicate resources (function-kcl issue #285). Use inline conditionals:

  ```kcl
  // WRONG
  obj = {metadata.name = name}
  if condition: obj.spec.replicas = 3

  // RIGHT
  obj = {
      metadata.name = name
      spec.replicas = 3 if condition else 1
  }
  ```

- **List comprehensions must be single-line** — multi-line fails CI.
- **Run `kcl fmt`** before every commit; strict formatting is enforced.
- **Readiness checks** via `option("params").ocds`:
  - Deployment: `status.conditions[type=Available, status=True]`
  - Service: `spec.clusterIP` assigned
  - HTTPRoute: `status.parents[].conditions[type=Accepted, status=True]`
  - Static-ready resources (HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease): always ready when created.
- **Validate** every change via `./scripts/validate-kcl-compositions.sh` or the `/crossplane-validator` skill.

## Security defaults (zero-trust by default)

- **CiliumNetworkPolicy required** for every composition that runs a pod. Default-deny; explicit egress + ingress.
- **No hardcoded credentials.** Use External Secrets Operator backed by OpenBao.
- **Pod security context** (always):
  ```yaml
  securityContext:
    runAsNonRoot: true
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    capabilities: { drop: [ALL] }
  ```
- **Resource requests + limits** mandatory (CPU & memory).
- **RBAC**: least privilege. Never cluster-admin for workloads.

## IAM conventions

- **EKS Pod Identity, never IRSA.** See ADR-0002 and the `EPI` composition.
- Policy scope: restrict to resources prefixed `xplane-*` (IAM, S3, Route53).
- **No deletion permissions** for stateful services (S3, IAM, Route53) — platform ops handle these.
- Policy doc inlined in the `EPI` spec; composition creates IAM role + policy + pod identity association.

## Observability standards

- **Metrics**: VictoriaMetrics. Use `ServiceMonitor` / `VMServiceScrape`.
- **Logs**: VictoriaLogs. Structured JSON; fields follow dot-notation (`kubernetes.container_name`, `log.level`).
- **Health checks**: liveness + readiness probes on every pod. Startup probe where init is slow.
- **Dashboards**: use `$${var}` (double dollar) in Grafana dashboard JSON to prevent Flux postBuild substitution.

## GitOps principles

- **Flux is the single source of truth** for cluster state.
- Dependency hierarchy: **Namespaces → CRDs → Crossplane → EKS Pod Identities → Security → Infrastructure → Observability → Applications.**
- Prefer `HelmRelease` over raw manifests when an upstream chart exists.
- Use `ArtifactGenerator` copy pattern `from: "@repo/dir/**"` with `to: "@artifact/dir/"` — NOT `from: "@repo/dir/"` (double-nests).

## Tailscale Gateway API

- Two separate Gateways by ACL scope:
  - **General** (`tag:k8s`): all members. Used for Harbor, Headlamp, Grafana, VictoriaMetrics.
  - **Admin** (`tag:admin`): `group:admin` only. Used for Hubble UI, VictoriaLogs, Grafana OnCall.
- `loadBalancerClass: tailscale` via `CiliumGatewayClassConfig`.
- ExternalDNS watches HTTPRoutes to create Route53 records.

## Documentation requirements

Every new composition must include:
- `README.md` with purpose, API, examples
- `settings-example.yaml` that renders successfully
- `examples/` directory with basic + complete example claims
- `main_test.k` covering resource counts, naming, security context

## Compliance checklist (for spec review)

- [ ] Resource naming: `xplane-*` prefix applied
- [ ] KCL: no post-creation mutation
- [ ] KCL: single-line list comprehensions
- [ ] CiliumNetworkPolicy defined (default-deny)
- [ ] External Secrets (no hardcoded credentials)
- [ ] Security context: non-root, read-only FS, no privilege escalation
- [ ] Resource limits set
- [ ] RBAC scoped; no cluster-admin
- [ ] IAM: EKS Pod Identity; policy scoped to `xplane-*`
- [ ] Observability: metrics + logs + health checks
- [ ] Documentation: README, settings-example, examples, tests

## Source of truth

`docs/specs/constitution.md` is the canonical text. This skill surfaces the rules proactively — it does not replace the constitution.

Related ADRs: `docs/decisions/0001-use-kcl-for-crossplane-compositions.md`, `docs/decisions/0002-eks-pod-identity-over-irsa.md`.
