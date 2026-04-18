---
name: create-pr
description: Create or update a Pull Request with AI-generated description, mermaid diagram, file walkthrough, and automatic SDD spec detection. Uses templates/pr-body.md for structure.
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

### 2. Detect spec context

Changed paths → spec type:

| Path pattern | Spec type |
|---|---|
| `infrastructure/base/crossplane/configuration/kcl/**/*.k`, `*-composition.yaml` | composition |
| `opentofu/**/*.tf`, `terramate.tm.hcl` | infrastructure |
| `*networkpolicy*`, `*rbac*`, `openbao/**`, `*cilium*policy*` | security |
| Multiple top-level dirs + HelmRelease/Kustomization | platform |

Find the spec directory for these changes (if one exists). The repo uses the 4-artifact structure (`spec.md`, `plan.md`, `tasks.md`, `clarifications.md`) so any of those files in the diff signals a spec:

```bash
git diff origin/${BASE:-main}...HEAD --name-only \
  | grep -oE 'docs/specs/[0-9]+-[a-z0-9-]+' | sort -u | head -1
```

For each detected spec directory, also note which artifacts changed (`spec.md` / `plan.md` / `tasks.md` / `clarifications.md`). Include them as bullet points under the **Specification** block:

```
## 📋 Specification

Implements [#<issue>](../issues/<issue>) — see [`<spec-dir>/`](../blob/main/<spec-dir>/).

Artifacts touched in this PR:
- `spec.md` (contract — should usually be unchanged after approval)
- `plan.md` (design)
- `tasks.md` (T00N progress)
- `clarifications.md` (CL-N entries appended)
```

If `spec.md` itself changed in a non-frozen way (i.e., this PR isn't the spec-creation PR), surface a warning — modifying the contract mid-implementation usually indicates scope creep that should be a follow-up spec.

If changes look spec-worthy but no spec directory exists, include the **Spec Recommendation** warning block from the template.

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
- Auto-detect spec directory by scanning `docs/specs/NNN-*` in the diff. Preserve existing references on update.
- Never skip hooks, never force-push without explicit user direction.

## Related skills

- `/spec` — create the spec this PR references
- `/commit` — commit with pre-commit validation before creating PR
- `/improve-pr <number>` — security + quality review after PR exists

## Supporting files

- [`templates/pr-body.md`](templates/pr-body.md) — full body template with both spec-present and spec-recommendation variants
- [`references/mermaid-styles.md`](references/mermaid-styles.md) — color classes and best practices for flow diagrams
