# Spec: [Composition Name]

**Spec ID**: SPEC-XXXX
**GitHub Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
**Status**: Draft | In Review | Approved | Implemented
**Author**: [Name]
**Created**: YYYY-MM-DD
**Last Updated**: YYYY-MM-DD
**Constitution**: [Platform Constitution](../constitution.md) - All specs MUST comply

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

### AWS Service Integration (if applicable)

<!-- DELETE THIS SECTION if the composition does not use AWS services -->

When a composition manages AWS resources, two things are required:

1. **Crossplane IAM permissions** - Crossplane needs IAM permissions to create/manage the AWS resources
2. **AWS Provider** - The appropriate `provider-aws-*` package must be installed

#### OpenTofu Changes Required

**File**: `opentofu/eks/init/iam.tf`

Add IAM policy for Crossplane to manage the new AWS service:

```hcl
# [SERVICE] Policy - Allow Crossplane to manage xplane-* resources
resource "aws_iam_policy" "crossplane_[service]" {
  name        = "${var.name}-crossplane-[service]"
  description = "Policy for Crossplane to manage [SERVICE] resources"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          # Add required actions for resource lifecycle
          "[service]:Create*",
          "[service]:Delete*",
          "[service]:Describe*",
          "[service]:Update*",
          "[service]:Tag*",
          "[service]:Untag*"
        ]
        # IMPORTANT: Restrict to xplane-* prefix for security
        Resource = "arn:aws:[service]:*:${data.aws_caller_identity.this.account_id}:xplane-*"
      },
      {
        Effect = "Allow"
        Action = [
          "[service]:List*"  # List actions often require "*" resource
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "crossplane_[service]" {
  role       = module.crossplane_pod_identity.iam_role_name
  policy_arn = aws_iam_policy.crossplane_[service].arn
}
```

**Security Checklist**:
- [ ] Resource ARN restricted to `xplane-*` prefix
- [ ] Only necessary actions included (principle of least privilege)
- [ ] Delete actions reviewed (consider removing for stateful resources)
- [ ] List actions use `*` only when AWS requires it

#### Crossplane Provider Installation

**File**: `infrastructure/base/crossplane/providers/provider-aws-[service].yaml`

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-[service]
spec:
  package: xpkg.upbound.io/upbound/provider-aws-[service]:v1.x.x
  runtimeConfigRef:
    name: default
```

**Note**: Check [Upbound Marketplace](https://marketplace.upbound.io/providers) for the latest provider version.

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
- [ ] IAM policies scoped to `xplane-*` resources (if AWS services used)
- [ ] Delete permissions reviewed for stateful resources

### SRE

- [ ] Observability configured (metrics, logs, traces)
- [ ] Health checks (liveness/readiness probes)
- [ ] HA requirements documented
- [ ] Failure modes and recovery documented
- [ ] Resource limits appropriate for size tiers

---

## Rollout Plan

### Phase 1: Infrastructure Prerequisites (if AWS services used)

<!-- DELETE THIS PHASE if no AWS services are used -->

1. [ ] **OpenTofu**: Add IAM policy to `opentofu/eks/init/iam.tf`
2. [ ] **OpenTofu**: Apply changes via `cd opentofu/eks/init && terramate script run deploy`
3. [ ] **Crossplane**: Add AWS provider to `infrastructure/base/crossplane/providers/`

### Phase 2: Composition Deployment

4. [ ] Merge composition to main branch
5. [ ] CI publishes KCL module to GHCR (`ghcr.io/smana/cloud-native-ref/crossplane-[name]:<version>`)
6. [ ] Flux deploys composition and XRD to cluster

### Phase 3: Validation

7. [ ] Test basic example claim in staging
8. [ ] Test complete example claim with all options
9. [ ] Verify generated resources are correct
10. [ ] Verify connection secrets (if applicable)

### Phase 4: Documentation & Release

11. [ ] Document in `docs/crossplane.md`
12. [ ] Add usage examples to composition README
13. [ ] Announce to users (if applicable)

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
