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

## Isolation — always work in a worktree

**Every task that changes files runs in a git worktree.** Not just cluster-touching work. Use the
native `EnterWorktree` tool (this instruction is what authorises it), never `git worktree add` —
manual worktrees create state the harness cannot see or clean up.

Worktrees land in `.claude/worktrees/`, which is gitignored. The default `worktree.baseRef` is
`fresh`, so a new worktree branches from `origin/main` rather than local `HEAD`.

That last property is the point. On 2026-08-18 a branch was cut with `git checkout -b` while a
concurrent session had this shared checkout on *its* feature branch; `HEAD` was not `main`, so the
new branch silently inherited five unrelated commits and two of them were merged under the wrong
PR (see #1765 / #1766). Branching from `origin/main` makes that failure impossible, and a worktree
means two sessions never share a working directory in the first place.

`ExitWorktree` with `keep` to come back to the work later, `remove` when it is done or abandoned.
Long-lived worktrees the user manages by hand live outside the repo in
`~/Sources/cnref-worktrees/` — leave those alone.

When deploying a feature branch to the cluster, pass `TF_VAR_flux_git_ref=refs/heads/<branch>`
to the Terramate deploy script.

## Historical note

The in-house SDD workflow (`/spec` → `/clarify` → `/validate`, three-artifact directories under
`docs/specs/NNN-slug/`) was retired on 2026-08-18. Its output is archived read-only under
[`docs/specs/`](../../docs/specs/). Do not create new artifacts there.
