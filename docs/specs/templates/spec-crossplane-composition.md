# Spec: [Composition Name]

**Spec ID**: SPEC-XXXX
**GitHub Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
**Status**: Draft | In Review | Approved | Implemented
**Author**: [Name]
**Created**: YYYY-MM-DD
**Last Updated**: YYYY-MM-DD

---

## Summary

[1-2 sentence description of the new composition and its purpose]

---

## Motivation

### Problem Statement

[What problem does this composition solve? Who experiences this problem?]

### User Stories & Acceptance Scenarios

#### User Story 1 - [Title] (Priority: P1)

[Description of user need]

**Why this priority**: [Justification]

**Acceptance Scenarios**:
1. **Given** [precondition], **When** [action], **Then** [expected result]
2. **Given** [precondition], **When** [action], **Then** [expected result]

#### User Story 2 - [Title] (Priority: P2)

[Description of user need]

**Acceptance Scenarios**:
1. **Given** [precondition], **When** [action], **Then** [expected result]

### Functional Requirements

- **FR-001**: System MUST [requirement]
- **FR-002**: System MUST [requirement]
- **FR-003**: System SHOULD [requirement]

### Success Criteria

- **SC-001**: [Measurable success criterion]
- **SC-002**: [Measurable success criterion]

### Non-Goals

- Non-goal 1 (explicitly out of scope)
- Non-goal 2 (will be addressed separately)

### Open Clarifications

<!-- Use [NEEDS CLARIFICATION: description] markers for unresolved questions -->
- [NEEDS CLARIFICATION: Example question that needs user input?]

---

## Design

### API Design (XRD)

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: [NewKind]
metadata:
  name: xplane-example
  namespace: apps
spec:
  # Required fields
  field1: value

  # Optional fields with defaults
  field2: default  # Optional, default: "default"
```

### Generated Resources

| Resource | Condition | Notes |
|----------|-----------|-------|
| Deployment | Always | Core workload |
| Service | Always | ClusterIP |
| HorizontalPodAutoscaler | `autoscaling.enabled` | Min/max replicas |
| CiliumNetworkPolicy | `networkPolicy.enabled` | Zero-trust default |
| ... | ... | ... |

### Size Configurations

| Size | CPU Request | Memory Request | CPU Limit | Memory Limit |
|------|-------------|----------------|-----------|--------------|
| small | 100m | 256Mi | 200m | 512Mi |
| medium | 250m | 512Mi | 500m | 1Gi |
| large | 500m | 1Gi | 1000m | 2Gi |

### Dependencies

- [ ] Existing composition: `SQLInstance` (if database needed)
- [ ] Existing composition: `EKSPodIdentity` (if AWS access needed)
- [ ] External operator: [operator/controller required]

---

## Implementation

### KCL Module Structure

```
infrastructure/base/crossplane/configuration/kcl/[name]/
├── main.k              # Main composition logic
├── kcl.mod             # Module definition (version, deps)
├── kcl.mod.lock        # Lock file
├── settings-example.yaml
└── README.md           # Comprehensive documentation
```

### Key Implementation Notes

1. **Readiness Checking**: [How will resource readiness be determined?]
   - Check observed status via `option("params").ocds`
   - Set `krm.kcl.dev/ready = "True"` conditionally

2. **Error Handling**: [How will errors be surfaced to users?]
   - Use XR status conditions
   - Clear error messages in events

3. **Mutation Avoidance**: Use inline conditionals (no post-creation mutation per issue #285)
   ```kcl
   # CORRECT - inline conditional
   metadata = {
       annotations = {
           if _ready:
               "krm.kcl.dev/ready" = "True"
       }
   }
   ```

### Example Usage

**Basic Example** (`examples/[name]-basic.yaml`):
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: [NewKind]
metadata:
  name: xplane-example
  namespace: apps
spec:
  field1: value
```

**Complete Example** (`examples/[name]-complete.yaml`):
```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: [NewKind]
metadata:
  name: xplane-example-complete
  namespace: apps
spec:
  field1: value
  field2: customValue
  # All optional fields shown...
```

---

## Validation

### Pre-Commit Checklist

Run `./scripts/validate-kcl-compositions.sh` which performs:

- [ ] `kcl fmt` passes (no reformatting needed)
- [ ] `kcl run` with settings-example.yaml succeeds
- [ ] `crossplane render` with basic example succeeds
- [ ] `crossplane render` with complete example succeeds
- [ ] Polaris audit score >= 85
- [ ] kube-linter passes with no errors
- [ ] Datree policy check passes

### Testing Strategy

- [ ] Basic example renders correctly
- [ ] Complete example renders correctly
- [ ] Edge cases documented and tested
- [ ] Error conditions produce clear messages

---

## Review Checklist

### Project Manager (PM)

- [ ] Problem statement is clear and specific
- [ ] User stories capture real needs
- [ ] Acceptance criteria are measurable
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Success metrics defined

### Platform Engineer

- [ ] XRD follows progressive complexity principle
- [ ] Consistent with existing composition patterns (App, SQLInstance)
- [ ] Resource naming follows `xplane-*` convention
- [ ] KCL avoids mutation pattern (issue #285)
- [ ] Examples (basic + complete) are provided
- [ ] README.md is comprehensive

### Security & Compliance

- [ ] Zero-trust networking considered (CiliumNetworkPolicy)
- [ ] Least-privilege RBAC
- [ ] Secrets via External Secrets (no hardcoded)
- [ ] Network policies defined
- [ ] Security context enforced (non-root, read-only FS)

### SRE

- [ ] Observability configured (metrics, logs, traces)
- [ ] Health checks (liveness/readiness probes)
- [ ] HA requirements documented
- [ ] Failure modes and recovery documented
- [ ] Resource limits appropriate for size tiers

---

## Rollout Plan

1. [ ] Merge composition to main branch
2. [ ] CI publishes KCL module to GHCR (`ghcr.io/smana/cloud-native-ref/crossplane-[name]:<version>`)
3. [ ] Update composition reference in cluster
4. [ ] Test with example claim in staging
5. [ ] Document in `docs/crossplane.md`
6. [ ] Announce to users (if applicable)

---

## Open Questions

- [ ] Question 1?
- [ ] Question 2?

---

## References

- Related ADR: [docs/decisions/XXXX-*.md]
- Similar composition: [infrastructure/base/crossplane/configuration/kcl/app/]
- External docs: [links]
- Design discussion: [issue/PR link]
