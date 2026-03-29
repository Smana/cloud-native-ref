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

## Prerequisites

- Git and GitHub CLI (`gh`) authenticated
- For Crossplane: Docker, `crossplane` CLI, `polaris`, `kube-linter`, `datree`
- For FluxCD: `fluxcd/agent-skills` plugin installed
