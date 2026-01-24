# Spec-Driven Development (SDD)

Specifications for non-trivial changes to the cloud-native-ref platform.

## Overview

SDD ensures thoughtful planning before implementation, reducing rework and catching design issues early. Inspired by [GitHub Spec Kit](https://github.com/github/spec-kit), our workflow balances rigor with simplicity:

```
/spec → Fill spec → Review (4 personas) → Implement → /create-pr → Archive
```

**Key Documents**:
- [Platform Constitution](./constitution.md) - Non-negotiable principles all specs must follow
- [Architecture Decision Records](../decisions/) - Cross-cutting technology decisions

## When to Create a Spec

Run `/spec` when making:

| Change Type | Examples |
|-------------|----------|
| **composition** | New KCL module, new XRD, Crossplane patterns |
| **infrastructure** | New OpenTofu stack, VPC changes, EKS upgrades |
| **security** | Network policies, RBAC, PKI, secrets management |
| **platform** | Multi-component features, observability, GitOps changes |

## When to Skip Specs

- Version bumps (Renovate PRs)
- Documentation-only changes
- Single-file bug fixes
- Minor configuration tweaks
- HelmRelease value changes

## Workflow

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   /spec     │───▶│  Fill spec  │───▶│   Review    │───▶│  Implement  │───▶│ /create-pr  │
│             │    │             │    │             │    │             │    │             │
│ Creates:    │    │ Complete:   │    │ 4 personas: │    │ Check off   │    │ References  │
│ - GH Issue  │    │ - Stories   │    │ - PM        │    │ tasks as    │    │ spec issue  │
│ - spec.md   │    │ - Design    │    │ - Platform  │    │ you go      │    │             │
│             │    │ - Tasks     │    │ - Security  │    │             │    │             │
│             │    │             │    │ - SRE       │    │             │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

### Step 1: Create Specification

```bash
/spec "Add Valkey caching composition"
/spec composition "Add queue composition for Kafka/SQS"
```

**Creates**:
- GitHub Issue `#XXX` (anchor for discussion)
- `docs/specs/001-valkey-caching/spec.md` (the spec)

### Step 2: Fill in the Spec

Edit the generated `spec.md`:

1. **Summary**: 1-2 sentences
2. **Problem**: Who has this problem? Why now?
3. **User Stories**: With Gherkin acceptance scenarios
4. **Requirements**: FR-001 (MUST), FR-002 (SHOULD)
5. **Success Criteria**: Measurable outcomes
6. **Design**: API, resources created, dependencies
7. **Tasks**: Phased checklist
8. **Clarifications**: Mark unclear items with `[NEEDS CLARIFICATION: ...]`

### Step 3: Review with 4 Personas

Before implementation, self-review the spec from each perspective:

| Persona | Focus Areas |
|---------|-------------|
| **Project Manager** | Problem clarity, user stories, acceptance criteria, scope |
| **Platform Engineer** | Design patterns, API consistency, KCL patterns, examples |
| **Security & Compliance** | Zero-trust, least privilege, secrets, network policies |
| **SRE** | Health checks, observability, resource limits, failure modes |

### Step 4: Resolve Clarifications

Discuss `[NEEDS CLARIFICATION]` markers conversationally with Claude:
- "What should be the default eviction policy?"
- Claude helps analyze options
- Update spec with `[CLARIFIED: answer]`

### Step 5: Implement

Work through the phased tasks in `spec.md`:
- Check off tasks as completed
- Verify success criteria are met

### Step 6: Create PR

```bash
/create-pr
```

Auto-references the spec: "Implements #XXX"

### Step 7: Archive

After merge:

```bash
mv docs/specs/001-valkey-caching docs/specs/done/
gh issue close XXX --comment "Implemented in PR #YYY"
```

## Directory Structure

```
docs/specs/
├── README.md              # This file
├── constitution.md        # Platform-wide principles
├── templates/
│   └── spec.md            # Template (~170 lines)
├── 001-feature-name/      # Active specs (directory per spec)
│   └── spec.md
└── done/                  # Archived specs
    └── 001-feature-name/
        └── spec.md
```

**Directory format**: `NNN-slug/` where:
- `NNN` = Sequential spec number (001, 002, ...)
- `slug` = Semantic description (kebab-case)

## Spec Structure

Every spec includes:

### Core Sections
1. **Metadata**: ID, issue link, status, type, date
2. **Summary**: 1-2 sentences
3. **Problem**: Who, what, why now
4. **User Stories**: Role, capability, benefit + Gherkin acceptance scenarios
5. **Requirements**: FR-XXX (MUST/SHOULD) + Non-goals
6. **Success Criteria**: SC-XXX measurable outcomes

### Design Sections
7. **API/Interface**: Example YAML
8. **Resources Created**: Table with conditions
9. **Dependencies**: Prerequisites checklist

### Execution Sections
10. **Tasks**: Phased checklist (Prerequisites → Implementation → Validation)
11. **Validation**: Verification steps
12. **Review Checklist**: 4 persona checklists

### Resolution Sections
13. **Clarifications**: `[NEEDS CLARIFICATION]` / `[CLARIFIED]` markers
14. **References**: Constitution, similar specs, ADRs

## User Stories (Gherkin-style)

```markdown
### US-1: Deploy Cached Application (Priority: P1)

As a **developer**, I want to deploy an app with managed caching,
so that I can improve response times without managing Redis myself.

**Acceptance Scenarios**:
1. **Given** an App claim with `cache.enabled: true`,
   **When** the composition reconciles,
   **Then** a Valkey instance is created in the same namespace
2. **Given** a Valkey instance is ready,
   **When** the app starts,
   **Then** the CACHE_URL environment variable is injected
```

## Review Personas

### Project Manager (PM)
- Problem statement is clear and specific
- User stories capture real user needs
- Acceptance scenarios are testable
- Scope is well-defined (goals AND non-goals)
- Success criteria are measurable

### Platform Engineer
- Design follows existing patterns (App, SQLInstance as references)
- API is consistent with other compositions
- Resource naming follows `xplane-*` convention
- KCL avoids mutation pattern (issue #285)
- Examples provided (basic + complete)

### Security & Compliance
- Zero-trust networking (CiliumNetworkPolicy defined)
- Least-privilege RBAC
- Secrets via External Secrets (no hardcoded credentials)
- Security context enforced (non-root, read-only FS where possible)
- IAM policies scoped to `xplane-*` resources (if AWS)

### SRE
- Health checks defined (liveness, readiness probes)
- Observability configured (metrics, logs)
- Resource limits appropriate
- Failure modes documented
- Recovery/rollback path clear

## Clarification Markers

Use `[NEEDS CLARIFICATION: ...]` for unresolved questions:

```markdown
- [NEEDS CLARIFICATION: Should cache support cross-namespace access?]
```

After discussing with Claude or stakeholders:

```markdown
- [CLARIFIED: No, cache is namespace-scoped for security isolation]
```

## Integration with Claude Code Skills

| Skill | Description |
|-------|-------------|
| `/spec [type] "description"` | Creates GitHub issue + spec directory |
| `/create-pr` | Auto-detects specs and references issue |
| `/commit` | Commit workflow with pre-commit validation |

See [`.claude/skills/README.md`](../../.claude/skills/README.md) for the complete skills reference.

## Platform Constitution

All specs must comply with the [Platform Constitution](./constitution.md). Key principles:

- Resource naming: `xplane-*` prefix
- KCL: No mutation after creation (issue #285)
- Security: Zero-trust, least privilege, External Secrets
- IAM: EKS Pod Identity, scoped to `xplane-*` resources
- Validation: Polaris 85+, kube-linter, Datree

## Related

- [Platform Constitution](./constitution.md) - Non-negotiable platform principles
- [Architecture Decision Records](../decisions/) - Cross-cutting technology choices
- [Crossplane Documentation](../crossplane.md) - Composition patterns
