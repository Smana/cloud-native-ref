# Spec: [Infrastructure Change Name]

**Spec ID**: SPEC-XXXX
**GitHub Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
**Status**: Draft | In Review | Approved | Implemented
**Author**: [Name]
**Created**: YYYY-MM-DD
**Last Updated**: YYYY-MM-DD
**Constitution**: [Platform Constitution](../constitution.md) - All specs MUST comply

---

## Summary

[1-2 sentence description of the infrastructure change]

---

## Motivation

### Problem Statement

[What infrastructure limitation or requirement drives this change?]

### Impact Assessment

| Aspect | Assessment |
|--------|------------|
| **Blast Radius** | [What could break if this goes wrong?] |
| **Rollback Complexity** | Easy / Moderate / Complex / Irreversible |
| **Downtime Required** | None / Maintenance Window / Full Outage |
| **Cost Impact** | [Monthly cost change estimate] |

### User Stories & Acceptance Scenarios

#### User Story 1 - [Title] (Priority: P1)

[Description of infrastructure need]

**Why this priority**: [Justification]

**Acceptance Scenarios**:
1. **Given** [precondition], **When** [action], **Then** [expected result]
2. **Given** [precondition], **When** [action], **Then** [expected result]

### Functional Requirements

- **FR-001**: Infrastructure MUST [requirement]
- **FR-002**: Infrastructure MUST [requirement]
- **FR-003**: Infrastructure SHOULD [requirement]

### Success Criteria

- **SC-001**: [Measurable success criterion, e.g., "Latency < 10ms"]
- **SC-002**: [Measurable success criterion]

### Non-Goals

- Non-goal 1 (explicitly out of scope)

### Open Clarifications

<!-- Use [NEEDS CLARIFICATION: description] markers for unresolved questions -->
- [NEEDS CLARIFICATION: Example question?]

---

## Design

### Architecture Diagram

```
[ASCII or mermaid diagram showing component relationships]
```

### OpenTofu/Terramate Changes

| Stack | Action | Resources Affected |
|-------|--------|-------------------|
| `opentofu/network/` | Modify | VPC, Subnets |
| `opentofu/eks/init/` | Add | New IAM role |
| `opentofu/eks/configure/` | Modify | Helm values |

### State Management

- **Backend**: S3 (existing)
- **State Lock**: DynamoDB (existing)
- **Migration Required**: Yes / No

### Key Entities

- **[Entity Name]**: [Description and purpose]
- **[Entity Name]**: [Description and purpose]

---

## Dependencies

### Prerequisites

- [ ] VPC exists with required subnets
- [ ] IAM roles available
- [ ] [Other dependencies]

### Dependent Systems

- [ ] [Systems that depend on this change]

---

## Implementation Plan

### Phase 1: Preparation

- [ ] Create feature branch
- [ ] Add/modify OpenTofu configuration
- [ ] Run `terramate script run preview`

### Phase 2: Apply

- [ ] Apply to dev/staging first (if applicable)
- [ ] Verify functionality
- [ ] Apply to production

### Phase 3: Validation

- [ ] Verify resources created correctly
- [ ] Test dependent services
- [ ] Update documentation

---

## Rollback Plan

1. [Step-by-step rollback procedure]
2. [State recovery if needed]
3. [Notification process]

---

## Cost Impact

| Resource | Monthly Cost | Notes |
|----------|--------------|-------|
| EC2 instances | $X | SPOT pricing assumed |
| NAT Gateway | $X | Per-AZ |
| **Total Delta** | **$X** | |

---

## Review Checklist

### Project Manager (PM)

- [ ] Problem statement is clear and specific
- [ ] User stories capture real infrastructure needs
- [ ] Impact assessment is complete
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Cost impact is documented

### Platform Engineer

- [ ] Terramate stack organization follows conventions
- [ ] Variables are parameterized appropriately
- [ ] State management is handled correctly
- [ ] Changes are idempotent

### Security & Compliance

- [ ] IAM policies follow least privilege
- [ ] No public endpoints exposed (unless required)
- [ ] Encryption at rest enabled
- [ ] Encryption in transit enabled
- [ ] Audit logging configured

### SRE

- [ ] Monitoring/alerting for new resources
- [ ] Disaster recovery considered
- [ ] Rollback plan is tested/testable
- [ ] Runbook updated (if needed)

---

## Validation Checklist

- [ ] `tofu validate` passes
- [ ] `trivy config` shows no critical issues
- [ ] `terramate script run preview` shows expected changes
- [ ] Peer review completed
- [ ] Cost estimate reviewed

---

## References

- Related ADR: [docs/decisions/XXXX-*.md]
- Existing stack reference: [opentofu/eks/init/]
- External docs: [links]
