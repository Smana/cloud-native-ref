# Claude Code Skills

This directory contains custom skills for Claude Code that extend AI capabilities for platform engineering workflows.

## Unified Skills System (v2.1.3+)

Since Claude Code v2.1.3, **Skills and Slash Commands are unified**. Each skill can be:
- **Auto-invoked**: Claude activates the skill when context matches
- **Explicitly invoked**: Via `/<skill-name>`

### Auto-Activation vs Explicit Invocation

| Skill | Auto-Activated When | Explicit Use |
|-------|---------------------|--------------|
| **kcl-composition-validator** | Working with `.k` files or Crossplane compositions | `/kcl-composition-validator` |
| **crossplane-renderer** | Testing compositions, rendering examples | `/crossplane-renderer` |
| **spec** | Never (requires explicit user intent) | `/spec` |
| **spec-status** | Never (requires explicit user intent) | `/spec-status` |
| **clarify** | Never (requires explicit user intent) | `/clarify` |
| **validate** | Never (requires explicit user intent) | `/validate` |
| **commit** | Never (user decides when to commit) | `/commit` |
| **create-pr** | Never (user decides when to create PR) | `/create-pr` |
| **improve-pr** | Never (user decides when to review) | `/improve-pr` |

## Available Skills

### Spec-Driven Development (SDD)

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec** | `/spec [type] "description"` | Create GitHub issue + spec directory with `spec:draft` label |
| **spec-status** | `/spec-status` | Show pipeline overview (Draft/Implementing/Done counts) |
| **clarify** | `/clarify [spec-file]` | Resolve `[NEEDS CLARIFICATION]` markers with structured options |
| **validate** | `/validate [spec-file]` | Validate spec completeness with actionable suggestions |

**Workflow**: `/spec` → `/spec-status` → `/clarify` → `/validate` → Implement → `/create-pr` → Auto-archive

For complete SDD documentation, see [`docs/specs/README.md`](../../docs/specs/README.md).

### Git & PR Workflows

| Skill | Usage | Description |
|-------|-------|-------------|
| **commit** | `/commit [--no-verify]` | Pre-commit validation + conventional commits |
| **create-pr** | `/create-pr [base]` or `--update <num>` | Create/update PR with mermaid diagram |
| **improve-pr** | `/improve-pr <pr-number>` | Security review + code improvements |

### Crossplane & KCL Validation

| Skill | Usage | Description |
|-------|-------|-------------|
| **kcl-composition-validator** | Auto-activated for KCL files | KCL formatting, syntax, render validation |
| **crossplane-renderer** | Auto-activated for compositions | Render + security validation (Polaris, kube-linter, Datree) |

## Skill Directory Structure

```
.claude/skills/
├── README.md                          # This file
├── spec/
│   └── SKILL.md                       # SDD: Create specifications
├── spec-status/
│   └── SKILL.md                       # SDD: Pipeline overview
├── clarify/
│   └── SKILL.md                       # SDD: Resolve clarification markers
├── validate/
│   └── SKILL.md                       # SDD: Validate spec completeness
├── commit/
│   ├── SKILL.md                       # Git commits with pre-commit
│   └── references/
│       └── emoji-guide.md             # Full emoji reference
├── create-pr/
│   └── SKILL.md                       # Create/update pull requests
├── improve-pr/
│   ├── SKILL.md                       # PR analysis & improvements
│   └── references/
│       └── report-template.md         # Full report template
├── kcl-composition-validator/
│   ├── SKILL.md                       # KCL validation
│   ├── examples.md
│   ├── quick-reference.md
│   └── reference.md
└── crossplane-renderer/
    ├── SKILL.md                       # Crossplane rendering
    ├── examples.md
    ├── quick-reference.md
    └── security-validation.md
```

## SKILL.md Format

Skills use Markdown with YAML frontmatter:

```markdown
---
name: skill-name
description: Brief description of what this skill does
allowed-tools: Read, Write, Bash(git:*), Bash(gh:*)
---

# Skill Title

## Usage
/skill-name [arguments]

## Workflow
[Steps the skill performs]

## Examples
[Usage examples]
```

### Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Skill identifier (used in `/<name>`) |
| `description` | Yes | Brief description (shown in `/help`) |
| `allowed-tools` | No | Tools the skill can use |

## Progressive Disclosure

For complex skills, use the `references/` directory:
- Main `SKILL.md`: Core content (~2000 words max)
- `references/*.md`: Detailed guides, templates, examples

Claude loads the main SKILL.md first, then references only when needed. This optimizes token usage.

## Complete Workflow Example

```bash
# 1. Create specification for new feature
/spec composition "Create a Valkey caching composition"
# → Creates: GitHub Issue #100 (label: spec:draft) + docs/specs/001-valkey-caching/spec.md

# 2. Fill in the spec
# - Problem statement
# - Requirements (FR-001, FR-002...)
# - Design (API, resources)
# - Tasks checklist

# 3. Check pipeline status
/spec-status
# → Shows: Draft: 1 (001-valkey-caching), Implementing: 0, Done: 15

# 4. Resolve clarifications with structured options
/clarify
# → Presents options for each [NEEDS CLARIFICATION] marker
# → Updates spec with [CLARIFIED: answer]

# 5. Validate spec completeness
/validate
# → Runs 8 validation checks
# → Provides actionable suggestions for any issues

# 6. Start implementation (update issue label)
gh issue edit 100 --remove-label "spec:draft" --add-label "spec:implementing"

# 7. Implement by working through tasks
# - Check off tasks in spec.md as completed

# 8. Commit changes with pre-commit validation
/commit

# 9. Create pull request (auto-links to spec)
/create-pr
# → PR body references: "Implements #100" and includes spec path

# 10. After merge, spec is auto-archived by GitHub Action
# → Spec moved to docs/specs/done/001-valkey-caching/
# → Issue #100 closed with spec:done label
```

## Adding New Skills

1. Create directory: `.claude/skills/<skill-name>/`
2. Create `SKILL.md` with frontmatter
3. Add `references/` for detailed content (optional)
4. Skill is auto-discovered by Claude Code

## Prerequisites

These skills require:
- Git installed and configured
- GitHub CLI (`gh`) authenticated: `gh auth login`
- Working in a git repository with GitHub remote

## Resources

- [Claude Code Documentation](https://docs.anthropic.com/en/docs/claude-code)
- [Claude Code Best Practices](https://www.anthropic.com/engineering/claude-code-best-practices)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
