# Spec: [Title]

**ID**: SPEC-XXX
**Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
**Status**: draft | in-review | approved | implementing | done
**Type**: composition | infrastructure | security | platform
**Created**: YYYY-MM-DD

---

## Summary

[1-2 sentences: What are we building and why?]

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
- [Will be addressed in future iteration]

---

## Success Criteria

- **SC-001**: [Measurable outcome, e.g., "Users can create a queue with < 5 fields"]
- **SC-002**: [Measurable outcome, e.g., "Connection latency < 10ms within cluster"]
- **SC-003**: [Measurable outcome, e.g., "All examples render with Polaris score >= 85"]

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

### Dependencies

- [ ] Prerequisite 1 (e.g., operator installed)
- [ ] Prerequisite 2 (e.g., IAM policy added)

---

## Tasks

### Phase 1: Prerequisites
- [ ] T001: [Task description]
- [ ] T002: [Task description]

### Phase 2: Implementation
- [ ] T003: [Task description]
- [ ] T004: [Task description]

### Phase 3: Validation & Documentation
- [ ] T005: [Task description]
- [ ] T006: [Task description]

---

## Validation

- [ ] Basic example renders successfully
- [ ] Complete example renders successfully
- [ ] Polaris score >= 85
- [ ] kube-linter passes
- [ ] E2E test passes (if applicable)
- [ ] Success criteria SC-001 through SC-XXX verified

---

## Review Checklist

Complete this checklist before implementation. Each persona represents a different perspective.

### Project Manager
- [ ] Problem statement is clear and specific
- [ ] User stories capture real user needs
- [ ] Acceptance scenarios are testable
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Success criteria are measurable

### Platform Engineer
- [ ] Design follows existing patterns (App, SQLInstance as references)
- [ ] API is consistent with other compositions
- [ ] Resource naming follows `xplane-*` convention
- [ ] KCL avoids mutation pattern (issue #285)
- [ ] Examples provided (basic + complete)

### Security & Compliance
- [ ] Zero-trust networking (CiliumNetworkPolicy defined)
- [ ] Least-privilege RBAC
- [ ] Secrets via External Secrets (no hardcoded credentials)
- [ ] Security context enforced (non-root, read-only FS where possible)
- [ ] IAM policies scoped to `xplane-*` resources (if AWS)

### SRE
- [ ] Health checks defined (liveness, readiness probes)
- [ ] Observability configured (metrics, logs)
- [ ] Resource limits appropriate
- [ ] Failure modes documented
- [ ] Recovery/rollback path clear

---

## Clarifications

<!-- Use [NEEDS CLARIFICATION: question?] for unresolved items -->
<!-- Resolve conversationally, then update with [CLARIFIED: answer] -->

- [NEEDS CLARIFICATION: Example question that needs discussion?]

---

## References

- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar: [link to similar spec or composition]
- ADR: [link to relevant architecture decision]
