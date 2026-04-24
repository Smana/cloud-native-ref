# Claude Code Skills

Custom skills for platform engineering workflows.

## Quick Start — core SDD flow (4 commands)

```bash
/spec "Add Redis caching"                # Create spec + GitHub issue (type inferred)
/clarify                                 # Resolve [NEEDS CLARIFICATION] → CL-N entries
/validate                                # Single quality gate (structural + cross-artifact)
/create-pr                               # Open PR (auto-detects spec directory)
```

Power tools (optional):

```bash
/spec-research <slug> "<question>"        # Deep ecosystem scan in forked subagent → research.md
/spec-status                              # Pipeline overview with dynamic context
/verify-spec <spec-dir>                   # Post-merge: prove SC-XXX against the live cluster
```

Other workflows:

```bash
/commit                                   # Pre-commit validate + conventional commit
/improve-pr <pr-number>                   # Security review + code improvements
/gitops-cluster-debug                     # Troubleshoot Flux issues
```

## Available Skills

### Spec-Driven Development (SDD)

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec** | `/spec "description"` (or `<type> "description"` to override) | Create GitHub issue + 3-artifact spec directory (`spec.md` + `plan.md` + `clarifications.md`) via `scripts/sdd/create-spec.sh`. Type is auto-inferred from the description |
| **clarify** | `/clarify [spec-dir]` | Append-only: replace `[NEEDS CLARIFICATION]` with `CL-N` reference; full deliberation logged in `clarifications.md` |
| **validate** | `/validate [spec-dir]` | Single quality gate — structural + FR coverage + CL-N references + constitution compliance |
| **create-pr** | `/create-pr [base]` or `--update <num>` | Create/update PR with mermaid diagram; auto-detects spec directory |

**Power tools** (optional, surface when needed):

| Skill | Usage | Description |
|-------|-------|-------------|
| **spec-research** | `/spec-research <slug> "<question>"` | Forked Explore subagent: Context7 + repo scan → writes `research.md` (without burning main context) |
| **spec-status** | `/spec-status` | Pipeline overview with `!\`cmd\`` dynamic context (counts computed before Claude reads) |
| **verify-spec** | `/verify-spec <spec-dir>` | Post-merge: check SC-XXX against live cluster via Flux + VictoriaMetrics MCPs, write `VERIFICATION.md` |

For complete SDD documentation see [`docs/specs/README.md`](../../docs/specs/README.md). Three auto-loaded rule files back the SDD flow when editing infra / security / spec files:

| Rule | Purpose |
|------|---------|
| [`spec-constitution.md`](../rules/spec-constitution.md) | Platform non-negotiables (`xplane-*`, KCL no-mutation, zero-trust, EKS Pod Identity) |
| [`verification.md`](../rules/verification.md) | Evidence-before-claims gate for every completion claim |
| [`debugging.md`](../rules/debugging.md) | 4-phase root-cause method for any failure mid-implementation |

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
