---
name: sync-branch
description: Rebase the current branch onto the latest origin/main before pushing, reviewing, or opening a PR. Fetches origin first so the comparison uses the real remote tip, not a stale local ref. Use when the user says "rebase", "sync with main", "is this up to date", "update the branch", before opening or updating a pull request, and whenever a review or a CI result would otherwise be judged against an outdated merge base.
compatibility: Requires git and a configured origin remote
allowed-tools: Bash(git:*)
---

# Sync branch onto origin/main

A branch that is behind `origin/main` produces a diff that no longer describes what will merge.
Reviews read the wrong merge base, CI passes against code nobody will ship, and conflicts surface
at merge time instead of now.

**Run this before every review, push and PR — not only when a conflict is suspected.**

## 1. Refuse the unsafe cases

Stop and report, do not proceed, when any of these hold:

| Condition | Check | Why |
|---|---|---|
| On the base branch itself | `git branch --show-current` is `main` | nothing to rebase |
| Uncommitted changes | `git status --porcelain` is non-empty | a rebase would strand them. Commit first — `ship-it` does this before calling you |
| Rebase already running | `test -d "$(git rev-parse --git-path rebase-merge)"`, same for `rebase-apply` | finish or abort it first |

Resolve that third one through `git rev-parse --git-path`, never as a literal `.git/…`. **In a
worktree `.git` is a file, not a directory** — it holds `gitdir: …/.git/worktrees/<name>` — so a
literal path can never match and the guard silently passes. This repo mandates a worktree for every
change, which would make the check dead everywhere it matters.

## 2. Fetch, then compare

The fetch is the point. Comparing against a local `origin/main` that was last updated hours ago
reports "up to date" on a branch that is not.

```bash
BASE="${BASE:-main}"
git fetch origin "$BASE"

if git merge-base --is-ancestor "origin/$BASE" HEAD; then
  echo "up to date with origin/$BASE"
else
  echo "behind origin/$BASE by $(git rev-list --count HEAD..origin/$BASE) commit(s)"
fi
```

When the branch is already up to date, say so and stop. Do not rebase for the sake of it — a
no-op rebase still rewrites committer dates and invalidates anyone's local copy.

## 3. Rebase

```bash
git rebase "origin/$BASE"
```

**On conflict**, resolve one file at a time and preserve intent from both sides:

```bash
git status --short | grep '^UU'   # conflicted files
# edit, then:
git add <file>
git rebase --continue
```

If the conflicts are not mechanically resolvable — two branches changed the same behaviour for
different reasons — `git rebase --abort` and ask. Guessing which side wins silently reverts
someone's work.

## 4. Push — only when asked

**Rebasing does not imply pushing.** A rebase rewrites history, so publishing it force-pushes a
branch someone may have checked out. Do that only when the caller has actually asked to push or to
open a PR — not as a side effect of "sync with main" or of a review.

When the push is wanted and the branch already exists on the remote, use `--force-with-lease`,
never bare `--force`: it refuses when someone else has pushed since you last fetched, which is the
entire failure it exists to prevent.

```bash
git push --force-with-lease origin "$(git branch --show-current)"
```

A branch that has never been pushed needs no force at all — a plain `git push -u origin <branch>`
belongs to whatever opens the PR.

## Report

State the outcome in one line, with the number that backs it:

- `already up to date with origin/main (a1b2c3d)`
- `rebased 4 commits onto origin/main (a1b2c3d), not pushed`
- `rebased 4 commits onto origin/main (a1b2c3d), force-pushed with lease`
- `rebase aborted — <file> conflicts on <what>, needs a decision`
