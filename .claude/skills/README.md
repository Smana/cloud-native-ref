# Claude Code Skills

Custom skills for platform engineering workflows.

## Quick Start

The core development workflow is the [Superpowers](https://github.com/obra/superpowers) plugin —
its skills auto-trigger, so there is nothing to type. See `CLAUDE.md` → *Development Workflow*.

The skills in this directory are repo-specific companions to that flow:

```bash
/spec-research <slug> "<question>"   # Deep ecosystem scan in a forked subagent → research doc
/verify-spec <design-doc>            # Post-merge: prove the criteria against the live cluster
/commit                              # Pre-commit validate + conventional commit
/create-pr                           # Open PR with a mermaid diagram, links the design doc
/improve-pr <pr-number>              # Security review + code improvements
/gitops-cluster-debug                # Troubleshoot Flux issues
```

## Available Skills

### Design and verification

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec-research** | `/spec-research <slug> "<question>"` | Forked Explore subagent: Context7 + repo scan → writes `docs/superpowers/specs/<date>-<slug>-research.md` without burning main context |
| **verify-spec** | `/verify-spec <design-doc>` | Post-merge: check a design's success criteria against the live cluster via the Flux + VictoriaMetrics/VictoriaLogs MCPs, write `<topic>-verification.md` |

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
