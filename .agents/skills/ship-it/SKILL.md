---
name: ship-it
description: Take a finished branch through the full pre-merge pipeline in one pass — rebase onto origin/main, simplify, prune prose, run the repo's validators and cite their output, review the diff, act on findings, then commit and open the PR. Use when the user says "ship it", "ready to merge", "open the PR", "this is done", "review and ship", or when implementation is complete and the next step is getting it reviewed and merged.
compatibility: Requires git, gh, and the repo's validation scripts
---

# Ship it

One ordered pipeline from "implementation done" to "PR open". The order is the point: each stage
feeds the next, and running them out of order wastes the work of the ones before it.

```
1. sync-branch     rebase onto origin/main, so every later stage sees the real merge base
2. simplify        quality cleanup, while the diff is still yours to reshape
3. prune prose     comment + doc concision pass
4. evidence gate   run the validators, cite the output
5. review          the reviewer sees the final shape, not a draft
6. act on findings fix, then re-run the evidence for whatever moved
7. commit + PR
```

Stop at any stage that fails. A stage that cannot pass is a finding, not something to note and
carry forward.

## 1. Rebase

Run the `sync-branch` skill. A review against a stale merge base reviews code that will not merge.

## 2. Simplify

Reuse, simplification, efficiency, altitude. Quality only — this is not the bug hunt.

Host mapping: `/simplify` in Claude Code; otherwise review the diff yourself against those four
axes. Keep it to code you actually changed.

## 3. Prune prose

Apply the gauntlet in [`references/prose.md`](references/prose.md) to every comment, doc and
message this branch adds or touches. The bar is asymmetric: deleting a real warning costs more
than leaving a mediocre comment, so keep anything you are unsure about and flag it.

## 4. Evidence gate

**No "done / fixed / passing / ready" claim without a fresh command run in the same response.**
Previous runs do not count — file and cluster state drift.

The claim-to-command table is in [`references/evidence.md`](references/evidence.md). Identify
which claims this branch makes, run those commands now, and cite the output inline as numbers or
an exit code, never as prose.

## 5. Review

Match effort to blast radius, not to diff size:

| Change | Effort |
|---|---|
| Single-file fix, version bump, doc edit | low |
| New manifest, chart values, claim | medium |
| New stack, composition pin, security or network policy | high |
| Anything touching PKI, IAM, or the OpenBao lineage | max |

Host mapping: `/code-review <effort>` in Claude Code. Elsewhere, dispatch a reviewer with
**crafted context** — the diff, the requirements, the base and head SHAs — never the session
history. The reviewer should evaluate the work product, not your reasoning about it.

## 6. Act on findings

Fix the real ones. Push back, with technical reasoning, on the ones that are wrong — a reviewer
being confidently mistaken is common, and implementing a bad suggestion to seem agreeable is worse
than arguing.

Any file you touch here re-enters stage 4. Re-run its evidence command.

## 7. Commit and open the PR

Run the `commit` skill, then `create-pr`. Both already carry the repo's conventions; do not
restate them here.

## Report

One line per stage, with the evidence:

```
rebased 4 commits onto origin/main (a1b2c3d)
simplify: 2 changes
prune: 11 comments deleted, 1 flagged
validate-manifests.sh: exit 0, Invalid: 0, Skipped: 0
review (high): 3 findings, 2 fixed, 1 disputed
PR #1234
```
