# Plan: [Title]

**Spec**: [SPEC-XXX](spec.md)
**Status**: draft | in-review | approved | implementing | done
**Last updated**: YYYY-MM-DD

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Every material change should be committed with a rationale; the append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: [Kind]
metadata:
  name: xplane-example
  namespace: apps
spec:
  # Required
  field1: value

  # Optional (with defaults)
  field2: default  # Optional, default: "default"
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| Resource1 | Always | Description |
| Resource2 | When X | Description |

### Key Entities

- **<Entity>**: <role / naming pattern>
- **<Entity>**: <role / naming pattern>

### Dependencies

- [ ] Prerequisite 1 (e.g., operator installed)
- [ ] Prerequisite 2 (e.g., IAM policy scoped)

### Alternatives considered

<!-- Brief: what else was on the table, why rejected. Detailed deliberations
go in clarifications.md as CL-N entries. Keep this to 2–3 sentences. -->

---

## Implementation Notes

- <Key implementation decision — references CL-N if deliberated>
- <Key implementation decision>

### File structure (if composition)

```
infrastructure/base/crossplane/configuration/kcl/<module>/
├── main.k
├── main_test.k
├── kcl.mod
├── settings-example.yaml
└── README.md
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders
- `crossplane render` with example succeeds
- Polaris score ≥ 85
- kube-linter passes

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [ ] Problem statement in spec.md is clear and specific
- [ ] User stories capture real user needs
- [ ] Acceptance scenarios are testable
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Success criteria are measurable

### Platform Engineer

- [ ] Design follows existing patterns (`App`, `SQLInstance`, `EPI` as references)
- [ ] API is consistent with other compositions
- [ ] Resource naming follows `xplane-*` convention
- [ ] KCL avoids mutation pattern (function-kcl #285)
- [ ] Examples provided (basic + complete)

### Security & Compliance

- [ ] Zero-trust networking (CiliumNetworkPolicy defined)
- [ ] Least-privilege RBAC
- [ ] Secrets via External Secrets (no hardcoded credentials)
- [ ] Security context enforced (non-root, read-only FS where possible)
- [ ] IAM policies scoped to `xplane-*` resources (if AWS)

### SRE

- [ ] Health checks defined (liveness, readiness probes)
- [ ] Observability configured (metrics → VictoriaMetrics, logs → VictoriaLogs)
- [ ] Resource requests + limits appropriate
- [ ] Failure modes documented
- [ ] Recovery / rollback path clear

---

## Phases (optional — for large features only)

<!-- Omit this section unless the feature truly needs multiple PRs.
For phased specs, each phase has its own tasks.md and SUMMARY.md under
phases/N-phase-name/. See docs/specs/README.md "Phased specs" for details. -->

| Phase | Scope | Depends on | Issue | Status |
|-------|-------|------------|-------|--------|
| 1-prereqs | <scope> | — | #XXX | [ ] not started |
| 2-core | <scope> | 1-prereqs | #XXX | [ ] not started |

---

## References

- Spec: [spec.md](spec.md)
- Tasks: [tasks.md](tasks.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar composition: <path>
- Related ADR: <link>
