---
name: create-pr
description: Create or update a Pull Request with AI-generated description, mermaid diagram, file walkthrough, and automatic design-doc detection. Uses templates/pr-body.md for structure.
when_to_use: |
  When the user says "open a PR", "create pull request", "push this as a PR",
  "open PR against main", "update my PR description", "--update <number>",
  or wants to ship a completed feature branch with a rich description.
disable-model-invocation: true
argument-hint: "[base-branch] | --update <pr-number>"
allowed-tools: Bash(git:*), Bash(gh:*), Read
---

# Create PR Skill

Generate and create/update a comprehensive PR using the shared body template.

## Mode detection

Parse `$ARGUMENTS`:
- Starts with `--update` or `-u` followed by a number → **Update Mode** on that PR.
- Anything else → **Create Mode** (argument is the base branch; default `main`).

## Create Mode

### 1. Gather diff information (parallel)

```bash
git log origin/${BASE:-main}..HEAD --oneline
git diff origin/${BASE:-main}...HEAD --stat
git diff origin/${BASE:-main}...HEAD
```

### 2. Detect the design context

Changed paths → change type:

| Path pattern | Change type |
|---|---|
| `infrastructure/base/crossplane/configuration/kcl/**/*.k`, `*-composition.yaml` | composition |
| `opentofu/**/*.tf`, `terramate.tm.hcl` | infrastructure |
| `*networkpolicy*`, `*rbac*`, `openbao/**`, `*cilium*policy*` | security |
| Multiple top-level dirs + HelmRelease/Kustomization | platform |

Find the design document behind these changes, if one exists. Non-trivial work goes through the
Superpowers flow (see `CLAUDE.md` → *Development Workflow*), which commits a design and a plan on
the branch:

```bash
git diff origin/${BASE:-main}...HEAD --name-only \
  | grep -oE 'docs/superpowers/(specs|plans)/[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.md' \
  | sort -u
```

When a design is detected, include the **Design** block:

```
## 📋 Design

Design: [`<date>-<topic>-design.md`](../blob/main/docs/superpowers/specs/<date>-<topic>-design.md)
Plan: [`<date>-<topic>-plan.md`](../blob/main/docs/superpowers/plans/<date>-<topic>-plan.md)

<one line: which part of the plan this PR delivers>
```

If the design doc itself changed materially in a PR that also implements it, say so in the
summary — a design moving during implementation usually signals scope creep worth calling out.

If the changes look substantial (a new composition, a new OpenTofu stack, a security-model change)
and no design doc is present, include the **Design Recommendation** warning block from the
template.

### 3. Render the PR body

Fill the template in [`templates/pr-body.md`](templates/pr-body.md). Apply the mermaid styling from [`references/mermaid-styles.md`](references/mermaid-styles.md). Keep title < 70 chars. Drop sections that do not apply (no empty stubs).

### 4. Create the PR

```bash
git push -u origin "$(git branch --show-current)"
gh pr create --base "${BASE:-main}" --title "<title>" --body "$BODY"
```

### 5. Output

Return only the PR URL.

## Update Mode

```bash
gh pr view "$PR_NUMBER" --json number,title,files,additions,deletions,baseRefName,body
gh pr diff "$PR_NUMBER"
```

Generate a fresh body using the same template. Update:

```bash
gh pr edit "$PR_NUMBER" --body "$BODY"
```

Return `Updated PR #<N>: <url>`.

## Content rules

- Title: conventional prefix (`feat(crossplane): ...`), under 70 chars.
- Summary: WHY, not WHAT. The file table shows WHAT.
- Auto-detect the design by scanning `docs/superpowers/specs/*-design.md` in the diff. Preserve existing references on update.
- Never skip hooks, never force-push without explicit user direction.

## Related skills

- `superpowers:brainstorming` — produces the design this PR references
- `/commit` — commit with pre-commit validation before creating PR
- `/improve-pr <number>` — security + quality review after PR exists

## Supporting files

- [`templates/pr-body.md`](templates/pr-body.md) — full body template with both design-present and design-recommendation variants
- [`references/mermaid-styles.md`](references/mermaid-styles.md) — color classes and best practices for flow diagrams
