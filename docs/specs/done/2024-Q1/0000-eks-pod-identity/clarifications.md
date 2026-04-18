# Clarifications Log — EKS Pod Identity Composition

**Spec**: [SPEC-0000](spec.md)

> This spec predates the append-only `clarifications.md` convention. The decisions below were captured retrospectively during the 2026-04-18 migration to the 4-artifact structure. Future updates use the standard `## CL-N` format.

---

## CL-1 — 2024-01-15 — IRSA vs EKS Pod Identity (retrospective)

**Asked by**: Platform team
**Context**: Pre-existing IRSA setup required OIDC providers per cluster, longer-lived JWTs, and per-cluster trust configuration. EKS Pod Identity was newly GA at the time.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | EKS Pod Identity | Simpler trust model; shorter-lived tokens; native EKS integration | Requires Pod Identity agent installed per cluster |
| B | Keep IRSA | Mature tooling; no new agent | Per-cluster OIDC complexity; longer-lived JWTs |

**Decision**: A — EKS Pod Identity
**Rationale**: Operational simplicity, shorter token lifetime, eliminates per-cluster OIDC plumbing. Recorded as ADR-0002.
**Decided by**: Platform team (2024-01)
**References**: [ADR-0002](../../../../decisions/0002-eks-pod-identity-over-irsa.md), [AWS Pod Identity docs](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

---

## CL-2 — 2024-01-15 — Cross-account IAM role assumption (retrospective)

**Asked by**: Platform team
**Context**: Some workloads (Harbor, observability) might eventually need cross-account access.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Defer (out of scope) | Keeps initial composition simple; single-account already covers all current needs | Future feature work needed when use case appears |
| B | Build in support now | One composition, no migration later | Premature complexity; no current consumer |

**Decision**: A — Defer
**Rationale**: No current consumer; YAGNI. Documented as a Non-Goal in spec.md.
**Decided by**: Platform team (2024-01)
**References**: spec.md → Non-Goals
