# Claude Code Skills

Custom skills for platform engineering workflows.

## Quick Start

```bash
/spec composition "Add Redis caching"    # Create spec + GitHub issue (4 artifacts)
/spec-research 003-redis "Redis vs Valkey caching patterns"  # Optional ecosystem research (forked subagent)
/clarify                                 # Resolve [NEEDS CLARIFICATION] → CL-N entries
/validate                                # Multi-artifact completeness check
/analyze                                 # Cross-artifact consistency check
/commit                                  # Pre-commit validate + conventional commit
/create-pr                               # Create PR (auto-detects spec directory)
/verify-spec docs/specs/done/2026-Q2/003-redis  # Post-merge verification of SC-XXX
/debug-spec docs/specs/done/2026-Q2/003-redis cache-stuck  # Persistent debug session
/gitops-cluster-debug                    # Troubleshoot Flux issues
```

## Available Skills

### Spec-Driven Development (SDD)

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec** | `/spec [type] "description"` | Create GitHub issue + 4-artifact spec directory (`spec.md` + `plan.md` + `tasks.md` + `clarifications.md`) via `scripts/sdd/create-spec.sh` |
| **spec-research** | `/spec-research <slug> "<question>"` | Forked Explore subagent: Context7 + repo scan → writes `research.md` |
| **spec-status** | `/spec-status` | Pipeline overview with `!\`cmd\`` dynamic context (counts computed before Claude reads) |
| **clarify** | `/clarify [spec-file]` | Append-only: replace `[NEEDS CLARIFICATION]` with `CL-N` reference; full deliberation logged in `clarifications.md` |
| **validate** | `/validate [spec-dir]` | Multi-artifact structural check via `scripts/validate-spec.sh` |
| **analyze** | `/analyze [spec-dir]` | Cross-artifact consistency: coverage gaps, ambiguity, constitution violations, drift |
| **verify-spec** | `/verify-spec <spec-dir>` | Post-merge: check SC-XXX against the live cluster, write `VERIFICATION.md` |
| **debug-spec** | `/debug-spec <spec-dir> <slug>` | Start or resume persistent debug session at `<spec-dir>/debug/<slug>.md` |
| **platform-constitution** | (auto-load, not user-invocable) | Non-negotiable platform rules surfaced when Claude touches infra/security code |

**Canonical workflow**:
```
/spec  →  /spec-research (optional)  →  /clarify  →  /validate  →  /analyze  →
Implement  →  /create-pr  →  Auto-archive (with SUMMARY)  →  /verify-spec  →  /debug-spec (if needed)
```

For complete SDD documentation, see [`docs/specs/README.md`](../../docs/specs/README.md). For the Platform Constitution surfaced by `platform-constitution`, see [`docs/specs/constitution.md`](../../docs/specs/constitution.md).

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
