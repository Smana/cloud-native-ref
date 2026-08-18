---
description: Repo-specific deltas for the Superpowers workflow — artifact locations and the gate that applies at each phase
globs:
  - "docs/superpowers/**"
---

# Superpowers Workflow — repo deltas

The methodology itself lives in the plugin (`superpowers:brainstorming`,
`superpowers:writing-plans`, `superpowers:subagent-driven-development`,
`superpowers:test-driven-development`, `superpowers:verification-before-completion`). This file
is only what differs in cloud-native-ref.

## Artifact locations

| Artifact | Path | Produced by |
|----------|------|-------------|
| Design | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | `superpowers:brainstorming` |
| Plan | `docs/superpowers/plans/YYYY-MM-DD-<topic>-plan.md` | `superpowers:writing-plans` |
| Research | `docs/superpowers/specs/YYYY-MM-DD-<topic>-research.md` | `/spec-research` |
| Verification | `docs/superpowers/specs/YYYY-MM-DD-<topic>-verification.md` | `/verify-spec`, post-merge |

Designs and plans are committed on the feature branch as the work proceeds, not merged to `main`
ahead of it. The PR body links the design.

## Gate at each phase

| Phase | Gate |
|-------|------|
| Design | [Platform constitution](../../docs/platform-constitution.md) — `xplane-*` naming, default-deny CiliumNetworkPolicy, EKS Pod Identity over IRSA, External Secrets, resource requests + limits |
| Implementation | `kcl-crossplane.md`, `crossplane-validation.md`, `cilium-network-policies.md`, `observability.md`, `opentofu.md` in this directory |
| Before claiming done | `process.md` in this directory — the evidence table. A fresh command run per claim, output cited inline |
| After merge | `/verify-spec` for anything with cluster-observable criteria |

## Isolation

Work that touches the running cluster belongs in a worktree
(`superpowers:using-git-worktrees`); worktrees live in `.claude/worktrees/`, which is gitignored.
When deploying a feature branch to the cluster, pass
`TF_VAR_flux_git_ref=refs/heads/<branch>` to the Terramate deploy script.

## Historical note

The in-house SDD workflow (`/spec` → `/clarify` → `/validate`, three-artifact directories under
`docs/specs/NNN-slug/`) was retired on 2026-08-18. Its output is archived read-only under
[`docs/specs/`](../../docs/specs/). Do not create new artifacts there.
