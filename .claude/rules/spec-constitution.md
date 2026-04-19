# SDD Constitution Rules

Auto-loaded when editing files under `docs/specs/**`, `infrastructure/**`, `security/**`, `observability/**`, or `tooling/**`. These are the non-negotiable platform rules every spec / composition / manifest must comply with. Source of truth: [`docs/specs/constitution.md`](../../docs/specs/constitution.md).

## Resource naming

All Crossplane-managed resources use the **`xplane-*`** prefix (e.g., `xplane-harbor`, `xplane-cert-manager-role`). The prefix is load-bearing for IAM scoping. Renames are delete+create — avoid casual renaming.

## KCL composition patterns

- **Never mutate a dict after creation** — causes duplicate resources (function-kcl issue #285). Use inline conditionals: `obj = { spec.X = ... if cond else default }`.
- **List comprehensions** must be single-line.
- Run **`kcl fmt`** before every commit; CI is strict.
- Validate with `./scripts/validate-kcl-compositions.sh` or the `/crossplane-validator` skill (4-stage: format / syntax / render / security).
- Native Kubernetes readiness via `option("params").ocds`:
  - Deployment: `status.conditions[type=Available, status=True]`
  - Service: `spec.clusterIP` assigned
  - HTTPRoute: `status.parents[].conditions[type=Accepted, status=True]`
- Static-ready resources (HPA, PDB, Gateway, CiliumNetworkPolicy, HelmRelease): always ready when created.

## Security defaults — zero-trust

- **CiliumNetworkPolicy required** for every composition that runs a pod. Default-deny, explicit allow.
- **No hardcoded credentials.** External Secrets Operator backed by OpenBao.
- **Pod security context** (always):
  ```yaml
  securityContext:
    runAsNonRoot: true
    readOnlyRootFilesystem: true
    allowPrivilegeEscalation: false
    capabilities: { drop: [ALL] }
  ```
- **Resource requests + limits** mandatory.
- **RBAC**: least privilege; never cluster-admin for workloads.

## IAM

- **EKS Pod Identity, never IRSA.** See ADR-0002 and the `EPI` composition.
- Policy scope: restrict to `xplane-*` resources (IAM, S3, Route53).
- **No deletion permissions** for stateful services (S3, IAM, Route53).

## Observability

- **Metrics**: VictoriaMetrics. Use `ServiceMonitor` / `VMServiceScrape`.
- **Logs**: VictoriaLogs. Structured JSON; dot-notation fields (`kubernetes.container_name`, `log.level`).
- **Health checks**: liveness + readiness probes on every pod.
- **Dashboards**: use `$${var}` (double dollar) in Grafana JSON to escape Flux postBuild substitution.

## GitOps

- **Flux is the single source of truth** for cluster state.
- Dependency hierarchy: **Namespaces → CRDs → Crossplane → EKS Pod Identities → Security → Infrastructure → Observability → Applications.**
- Prefer `HelmRelease` over raw manifests when an upstream chart exists.
- `ArtifactGenerator` copy: `from: "@repo/dir/**"` with `to: "@artifact/dir/"` (NOT `from: "@repo/dir/"` — double-nests).

## Documentation

Every new composition includes:
- `README.md` — purpose, API, examples
- `settings-example.yaml` — renders successfully
- `examples/` — basic + complete claims
- `main_test.k` — resource counts, naming, security context

## Spec compliance checklist

- [ ] Resource naming: `xplane-*`
- [ ] KCL: no post-creation mutation; single-line list comprehensions
- [ ] CiliumNetworkPolicy defined (default-deny)
- [ ] External Secrets (no hardcoded credentials)
- [ ] Security context: non-root, read-only FS, no privilege escalation
- [ ] Resource limits set
- [ ] RBAC scoped; no cluster-admin
- [ ] IAM: EKS Pod Identity; policy scoped to `xplane-*`
- [ ] Observability: metrics + logs + health checks
- [ ] Documentation: README, settings-example, examples, tests
- [ ] All 3 spec artifacts present (spec.md / plan.md / clarifications.md)
- [ ] No inline `[CLARIFIED:]` in spec.md (decisions are CL-N entries)

Related ADRs: `docs/decisions/0001-use-kcl-for-crossplane-compositions.md`, `docs/decisions/0002-eks-pod-identity-over-irsa.md`.
