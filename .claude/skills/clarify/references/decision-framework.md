# Decision Framework for Clarifications

How to generate structured options when resolving `[NEEDS CLARIFICATION: ...]`. Apply all four perspectives; surface 2–3 options with clear trade-offs; recommend one.

## Security perspective

- **Zero-trust**: default deny; explicit allow. Prefer options that add a `CiliumNetworkPolicy`.
- **Least privilege**: narrow IAM/RBAC scope; no cluster-admin for workloads.
- **Secrets**: always External Secrets Operator; never hardcoded credentials.
- **Pod security context**: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, resource limits.

## Platform engineering perspective

- **Consistency**: align with `App`, `SQLInstance`, `EPI` compositions.
- **Naming**: `xplane-*` prefix (constitution).
- **KCL patterns**: no mutation after creation (function-kcl #285). Prefer inline conditionals, single-line list comprehensions.
- **API design**: progressive complexity — simple defaults, advanced options behind opt-in fields.

## SRE perspective

- **Health checks**: liveness, readiness, startup probes defined.
- **Observability**: metrics (VictoriaMetrics), logs (VictoriaLogs), standard labels.
- **Resource limits**: CPU and memory requests + limits. PDB for HA services.
- **Failure modes**: explicit recovery path. Graceful shutdown.
- **Operational complexity**: fewer moving parts > more.

## Product manager perspective

- **User experience**: minimum fields to get started. Defaults that work for 80% of cases.
- **Progressive disclosure**: advanced options hidden behind `advanced:` or separate fields.
- **Scope**: split into P1 / P2 if multiple personas want conflicting things.

## Recommendation rubric

Recommend the option that **simultaneously**:

1. Satisfies the constitution (no hard violations).
2. Matches the closest existing composition (`App`, `SQLInstance`, `EPI`) unless there is a documented reason to diverge.
3. Keeps the API minimal for the common case.
4. Preserves zero-trust / least-privilege defaults.

If no single option wins on all four, surface the trade-off explicitly and ask the user to pick.

## Updating the spec after decision

Replace the marker in-place:

```
Before: - [NEEDS CLARIFICATION: question]
After:  - [CLARIFIED: <answer> — <one-line rationale>]
```

Keep the rationale terse (one line). If the decision has broader reasoning, link to a future `clarifications.md` append-only log (P0.2 of the SDD redesign) or an ADR.

## Common clarification topics and canonical answers

| Topic                          | Canonical answer                                                               |
|--------------------------------|--------------------------------------------------------------------------------|
| IAM auth pattern               | EKS Pod Identity (never IRSA) — ADR-0002                                       |
| Template language              | KCL — ADR-0001                                                                 |
| Ingress                        | Gateway API + Cilium (`loadBalancerClass: tailscale` for private)              |
| Secret backend                 | External Secrets Operator + OpenBao                                            |
| CNI                            | Cilium (kube-proxy replacement)                                                |
| GitOps                         | Flux; dependency hierarchy: ns → CRDs → Crossplane → security → infra → apps    |
| Metrics                        | VictoriaMetrics                                                                |
| Logs                           | VictoriaLogs                                                                   |
| Certificates                   | cert-manager + OpenBao PKI (Root → Intermediate → Leaf)                         |

Reference these when the question maps onto a prior decision — the answer is usually "use the standard", not a new deliberation.
