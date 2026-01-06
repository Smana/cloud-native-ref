# Spec-Driven Development (SDD)

This directory contains formal specifications for non-trivial changes to the cloud-native-ref platform.

## Overview

SDD ensures thorough planning before implementation, reducing rework and catching issues early. Based on [GitHub Spec Kit](https://github.com/github/spec-kit), our workflow follows these stages:

```
Specify → Clarify → Plan → Tasks → Implement → Validate
```

**Key Documents**:
- [Platform Constitution](./constitution.md) - Non-negotiable principles all specs must follow
- [Architecture Decision Records](../decisions/) - Cross-cutting technology decisions

## When to Create a Spec

Run `/specify [type]` when making:

| Change Type | Examples | Template |
|-------------|----------|----------|
| **composition** | New KCL module, new XRD, Crossplane patterns | `spec-crossplane-composition.md` |
| **infrastructure** | New OpenTofu stack, VPC changes, EKS upgrades | `spec-infrastructure.md` |
| **security** | Network policies, RBAC, PKI, secrets management | `spec-security.md` |
| **platform** | Multi-component features, observability, GitOps changes | `spec-platform-capability.md` |

## When to Skip Specs

- Version bumps (Renovate PRs)
- Documentation-only changes
- Single-file bug fixes
- Minor configuration tweaks
- HelmRelease value changes

## Workflow

```bash
# 1. Create specification (creates GitHub issue + spec file)
/specify composition "Add Valkey caching composition"
# Creates: GitHub Issue #XXX + docs/specs/active/0001-#XXX-valkey-caching.md

# 2. Fill in the spec template
#    - User stories with Given/When/Then acceptance scenarios
#    - Functional requirements (FR-001, FR-002...)
#    - Success criteria (SC-001, SC-002...)
#    - Add [NEEDS CLARIFICATION: ...] markers for uncertain items

# 3. Resolve clarifications interactively
/clarify
# Walks through each [NEEDS CLARIFICATION] marker and updates the spec

# 4. Generate task breakdown (optional)
/tasks
# Creates dependency-ordered tasks from the spec's Rollout Plan

# 5. Validate spec is complete
./scripts/validate-spec.sh
# Checks: required sections, no unresolved markers, constitution compliance

# 6. Self-review using the 4-persona checklists

# 7. Implement changes following the spec

# 8. Create PR (auto-references issue: "Implements #XXX")
/create-pr

# 9. After merge, archive the spec and close the issue
mv docs/specs/active/XXXX-*.md docs/specs/completed/
gh issue close XXX
```

## Two-Document Model

Inspired by [vfarcic/dot-ai](https://github.com/vfarcic/dot-ai), specs use a two-document model:

| Document | Purpose | Location |
|----------|---------|----------|
| **GitHub Issue** | Immutable anchor, discussion, "what/why" | GitHub Issues |
| **Spec File** | Detailed design, checklists, "how" | `docs/specs/active/` |

The issue provides discoverability and discussion; the spec file contains implementation details.

## Directory Structure

```
docs/specs/
├── README.md           # This file
├── constitution.md     # Platform-wide non-negotiable principles
├── templates/          # Spec templates (do not edit directly)
│   ├── spec-crossplane-composition.md
│   ├── spec-infrastructure.md
│   ├── spec-security.md
│   └── spec-platform-capability.md
├── active/             # Specs currently in progress
│   └── 0001-#42-valkey-caching.md   # Linked to GitHub issue #42
└── completed/          # Archived specs (for reference)
    └── 0001-#42-valkey-caching.md
```

**Filename format**: `XXXX-#ISSUE-slug.md` where:
- `XXXX` = Sequential spec number (0001, 0002, ...)
- `#ISSUE` = GitHub issue number for traceability
- `slug` = Semantic description (kebab-case)

## Spec Structure

Every spec includes:

1. **Summary**: 1-2 sentence description
2. **Motivation**: Problem statement, user stories (P1/P2/P3 priority), functional requirements (FR-XXX), success criteria (SC-XXX)
3. **Design**: Architecture, API/schema design, key entities
4. **Implementation**: Phases, tasks, validation checklist
5. **Review Checklist**: 4-persona self-review

## Review Personas

Each spec template includes a self-review checklist covering these perspectives:

### Project Manager (PM)
- Problem statement is clear and specific
- User stories capture real needs
- Acceptance criteria are measurable
- Scope is well-defined (goals AND non-goals)
- Success metrics defined

### Platform Engineer
- Design follows existing patterns (App, SQLInstance as references)
- Resource naming follows `xplane-*` convention
- KCL avoids mutation pattern (issue #285)
- Examples (basic + complete) are provided

### Security & Compliance
- Zero-trust networking considered
- Least-privilege RBAC
- Secrets via External Secrets (no hardcoded)
- Network policies defined

### SRE
- Observability configured (metrics, logs, traces)
- HA requirements documented
- Failure modes and recovery documented
- Backup/DR strategy defined (if applicable)

## Spec Key Elements

### User Stories (Gherkin-style)

```markdown
#### User Story 1 - Deploy Cached Application (Priority: P1)

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

### Functional Requirements

```markdown
- **FR-001**: System MUST create Valkey instance when `cache.enabled: true`
- **FR-002**: System MUST inject CACHE_URL into application pods
- **FR-003**: System SHOULD support TLS encryption for cache connections
```

### Success Criteria

```markdown
- **SC-001**: Cache hit rate > 80% for repeated queries
- **SC-002**: Connection latency < 5ms within cluster
```

### Clarification Markers

Use `[NEEDS CLARIFICATION: ...]` for unresolved questions:

```markdown
- [NEEDS CLARIFICATION: Should cache support cross-namespace access?]
- [NEEDS CLARIFICATION: What eviction policy should be default?]
```

## Integration with Claude Code

| Command | Description |
|---------|-------------|
| `/specify [type]` | Creates GitHub issue + spec file from template |
| `/clarify [file]` | Resolves `[NEEDS CLARIFICATION]` markers interactively |
| `/tasks [file]` | Generates task breakdown from spec's Rollout Plan |
| `/create-pr` | Auto-detects specs in `active/` and links them in PR |
| `/commit` | Standard commit workflow (unchanged) |

**Validation Script**:
```bash
./scripts/validate-spec.sh [spec-file]
```
Validates: required sections, no unresolved markers, constitution compliance, no placeholders.

## Related

- [Platform Constitution](./constitution.md) - Non-negotiable platform principles
- [Architecture Decision Records](../decisions/) - Cross-cutting technology choices
- [Crossplane Documentation](../crossplane.md) - Composition patterns
