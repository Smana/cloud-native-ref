# Claude Code Skills

Custom skills for platform engineering workflows.

## Quick Start

```bash
/spec composition "Add Redis caching"   # Create spec + GitHub issue
/commit                                  # Validate + commit changes
/create-pr                               # Create PR with description
/gitops-cluster-debug                    # Troubleshoot Flux issues
```

## Available Skills

### Spec-Driven Development (SDD)

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec** | `/spec [type] "description"` | Create GitHub issue + spec directory with `spec:draft` label |
| **spec-status** | `/spec-status` | Show pipeline overview (Draft/Implementing/Done counts) |
| **clarify** | `/clarify [spec-file]` | Resolve `[NEEDS CLARIFICATION]` markers with structured options |
| **validate** | `/validate [spec-file]` | Validate spec completeness with actionable suggestions |

**Workflow**: `/spec` -> `/spec-status` -> `/clarify` -> `/validate` -> Implement -> `/create-pr` -> Auto-archive

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
| **crossplane-validator** | Auto-activates for composition files | KCL formatting, syntax, rendering, and security validation (Polaris, kube-linter, Datree) |

### FluxCD GitOps (Plugin: `fluxcd/agent-skills`)

| Skill | Usage | Description |
|-------|-------|-------------|
| **gitops-knowledge** | `/gitops-knowledge` | Flux concepts, YAML generation, validation, common mistakes |
| **gitops-repo-audit** | `/gitops-repo-audit` | 6-phase GitOps repo audit (discovery, validation, security) |
| **gitops-cluster-debug** | `/gitops-cluster-debug` | Live cluster troubleshooting via `flux-operator-mcp` |

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
└── crossplane-validator/
    ├── SKILL.md                       # Crossplane composition validation
    └── references/
        └── kcl-patterns.md            # KCL patterns & security recipes
```

## SKILL.md Format

Skills use Markdown with YAML frontmatter:

```markdown
---
name: skill-name
description: Brief description of what this skill does
disable-model-invocation: true
argument-hint: "[arg1] [arg2]"
paths: "src/**/*.ts"
allowed-tools: Read, Write, Bash(git:*)
---

# Skill Title

## Usage
/skill-name [arguments]
```

### Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Skill identifier (defaults to directory name) |
| `description` | Yes | Brief description (shown in `/help`, max 250 chars) |
| `disable-model-invocation` | No | `true` to prevent auto-invocation (use for side-effect operations) |
| `argument-hint` | No | Hint shown in autocomplete |
| `paths` | No | Glob patterns for auto-activation when editing matching files |
| `allowed-tools` | No | Restrict which tools the skill can use |

## Prerequisites

- Git installed and configured
- GitHub CLI (`gh`) authenticated: `gh auth login`
- For Crossplane: Docker running, `crossplane` CLI, `polaris`, `kube-linter`, `datree`
- For FluxCD skills: `fluxcd/agent-skills` plugin installed
