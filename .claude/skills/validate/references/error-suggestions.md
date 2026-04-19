# Validate Error Suggestions

Canonical remediation text for each error class `scripts/validate-spec.sh` can emit. Emit these when reporting failures.

## Missing required sections

```
❌ Missing: ## <Section Name>

Fix: Add the section header and fill content. Template:
<section-specific template>
```

Required sections and their minimal templates:

### Summary
```markdown
## Summary

<1–2 sentences describing what is being built and why>
```

### Problem
```markdown
## Problem

<Who has this problem? What happens without this? Why now?>
```

### User Stories
```markdown
## User Stories

### US-1: <Title> (Priority: P1)
As a **<role>**, I want **<capability>**, so that **<benefit>**.

**Acceptance Scenarios**:
1. **Given** <precondition>, **When** <action>, **Then** <result>
```

### Requirements
```markdown
## Requirements

### Functional
- **FR-001**: System MUST <requirement>
- **FR-002**: System MUST <requirement>

### Non-Goals
- <out of scope>
```

### Success Criteria
```markdown
## Success Criteria

- **SC-001**: <measurable outcome>
- **SC-002**: <measurable outcome>
```

### Design
```markdown
## Design

### API / Interface
<YAML example>

### Resources Created
| Resource | Condition | Notes |
|----------|-----------|-------|

### Dependencies
- [ ] <prerequisite>
```

### Tasks
```markdown
## Tasks

### Phase 1: Prerequisites
- [ ] T001: <task>

### Phase 2: Implementation
- [ ] T002: <task>

### Phase 3: Validation
- [ ] T003: <task>
```

## Unresolved clarifications

```
❌ Found <N> unresolved [NEEDS CLARIFICATION] markers.

Fix: Run /clarify to resolve with structured options.
Locations:
  Line <L1>: <question>
  Line <L2>: <question>
```

## Incomplete review checklist

```
⚠️  Review Checklist: <done>/<total> complete (<pct>%).

Fix: Review spec from each persona's perspective. Currently:
  - Project Manager:    <done>/5
  - Platform Engineer:  <done>/5
  - Security:           <done>/5
  - SRE:                <done>/5

Each persona enforces non-negotiable rules — do not skip.
Full checklist in docs/specs/templates/spec.md.
```

## Too few requirements or success criteria

```
⚠️  Only <N> functional requirements found.

Fix: Add at least 2 FR-XXX entries. FR-001 should map to the
primary user need; subsequent FRs cover secondary capabilities
and non-negotiable constraints (security, observability).
```

```
⚠️  Only <N> success criteria found.

Fix: Add at least 2 SC-XXX entries with MEASURABLE outcomes.
Avoid vague words ("fast", "scalable"). Prefer:
  - Latency: p95 < 100ms
  - Throughput: 1000 req/s sustained
  - Reliability: SLO 99.9% monthly
```

## Unresolved placeholders

```
❌ Unfilled template placeholders found.

Fix: Replace the following with real content:
  SPEC-XXX  → actual spec number (e.g., SPEC-003)
  YYYY-MM-DD → today's date
  [Title]   → actual title
  [role]    → actual user role
  [NEEDS CLARIFICATION: example] → real question or remove
```

## Missing GitHub issue link

```
❌ No GitHub issue reference found.

Fix: Add an Issue line to the metadata header:
  **Issue**: [#XXX](https://github.com/Smana/cloud-native-ref/issues/XXX)
```

## Missing constitution reference

```
⚠️  No reference to docs/specs/constitution.md.

Fix: Add a References section linking the constitution:
  ## References
  - Constitution: [docs/specs/constitution.md](../constitution.md)
```

## Tasks missing structured IDs

```
⚠️  Tasks lack structured IDs (T001, T002, ...).

Fix: Prefix each task with a unique ID so /create-pr and
/verify-spec can track completion:
  - [ ] T001: <description>
  - [ ] T002: <description>
```

## Pass message

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Result: PASSED

Next steps:
  - <next action based on spec state>
```
