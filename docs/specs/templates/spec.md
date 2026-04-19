# Spec: [Title]

**ID**: SPEC-XXX
**Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
**Status**: draft | in-review | approved | implementing | done
**Type**: composition | infrastructure | security | platform
**Created**: YYYY-MM-DD
**Last updated**: YYYY-MM-DD

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

[1–2 sentences: what are we building and why?]

---

## Problem

[Who experiences this problem? What happens without this solution? Why now?]

---

## User Stories

### US-1: [Story Title] (Priority: P1)

As a **[role]**, I want **[capability]**, so that **[benefit]**.

**Acceptance Scenarios**:
1. **Given** [precondition], **When** [action], **Then** [expected result]
2. **Given** [precondition], **When** [action], **Then** [expected result]

### US-2: [Story Title] (Priority: P2)

As a **[role]**, I want **[capability]**, so that **[benefit]**.

**Acceptance Scenarios**:
1. **Given** [precondition], **When** [action], **Then** [expected result]

---

## Requirements

### Functional

- **FR-001**: System MUST [requirement]
- **FR-002**: System MUST [requirement]
- **FR-003**: System SHOULD [optional requirement]

### Non-Goals

- [Explicitly out of scope]
- [Deferred to future iteration]

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: [Measurable outcome, e.g., "pods authenticate to S3 via Pod Identity within 30s of creation"]
- **SC-002**: [Measurable outcome, e.g., "Polaris audit score ≥ 85"]
- **SC-003**: [Measurable outcome, e.g., "Crossplane XR Ready condition true within 60s of apply"]

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] [NEEDS CLARIFICATION: Example question?]

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar spec: <link>
- Related ADR: <link>
