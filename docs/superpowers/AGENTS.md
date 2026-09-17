# Superpowers workflow — repo deltas

The methodology lives in the [Superpowers](https://github.com/obra/superpowers) plugin
(`brainstorming`, `writing-plans`, `subagent-driven-development`, `test-driven-development`,
`verification-before-completion`). This file is only what differs here.

```
brainstorming   -> specs/YYYY-MM-DD-<topic>-design.md
  writing-plans -> plans/YYYY-MM-DD-<topic>-plan.md
    subagent-driven-development (or executing-plans)
      /verify-spec -> specs/YYYY-MM-DD-<topic>-verification.md
        ship-it
```

| Artifact | Path | Produced by |
|---|---|---|
| Design | `specs/YYYY-MM-DD-<topic>-design.md` | `brainstorming` |
| Plan | `plans/YYYY-MM-DD-<topic>-plan.md` | `writing-plans` |
| Research | `specs/YYYY-MM-DD-<topic>-research.md` | `spec-research` |
| Verification | `specs/YYYY-MM-DD-<topic>-verification.md` | `verify-spec`, post-merge |

Designs and plans are committed **on the feature branch** as the work proceeds, not merged to
`main` ahead of it. The PR body links the design.

## The gate at each phase

| Phase | Gate |
|---|---|
| Design | [Platform constitution](../platform-constitution.md). **Plus**: a technology choice with a rejected alternative needs an ADR on the branch before the PR opens |
| Implementation | The `AGENTS.md` in whichever directory you are changing |
| Before claiming done | The evidence table in [`.agents/skills/ship-it/references/evidence.md`](../../.agents/skills/ship-it/references/evidence.md) — a fresh command run per claim, output cited inline |
| After merge | `/verify-spec` for anything with cluster-observable criteria |

## When a design is required

| Change type | Examples |
|---|---|
| New Crossplane composition | new KCL module, new XRD |
| Major infrastructure | new OpenTofu stack, VPC changes, EKS upgrades |
| Security changes | network policies, RBAC, PKI, secrets |
| Platform capabilities | multi-component features, observability |
| New technology | anything chosen over a named alternative |

**Skip it for**: version bumps, documentation-only changes, single-file bug fixes, minor config
changes, HelmRelease value tweaks.

## Isolation

**Every task that changes files runs in a git worktree** — not just cluster-touching work. Use the
native `EnterWorktree` tool, never `git worktree add`: manual worktrees create state the harness
cannot see or clean up. They land in `.claude/worktrees/`, which is gitignored, and
`worktree.baseRef` defaults to `fresh` so a new worktree branches from `origin/main` rather than
local `HEAD`.

That last property is the point. On 2026-08-18 a branch was cut with `git checkout -b` while a
concurrent session had the shared checkout on *its* feature branch. `HEAD` was not `main`, so the
new branch silently inherited five unrelated commits, two of which were merged under the wrong PR
(#1765 / #1766). Branching from `origin/main` makes that failure impossible.

`ExitWorktree` with `keep` to return later, `remove` when done or abandoned. Long-lived worktrees
managed by hand live outside the repo in `~/Sources/cnref-worktrees/` — leave those alone.

Deploying a feature branch to the cluster: `TF_VAR_flux_git_ref=refs/heads/<branch>`.

## Historical note

The in-house SDD workflow (`/spec` → `/clarify` → `/validate`, three-artifact directories under
`docs/specs/NNN-slug/`) was retired on 2026-08-18. Its output is archived read-only under
[`../specs/`](../specs/). Do not create new artifacts there.
