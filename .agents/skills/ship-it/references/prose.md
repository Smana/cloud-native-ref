# Prune prose

Every comment, doc paragraph and message this branch adds or touches goes through the gauntlet
below. Walk it in order and stop at the first verdict that applies.

The keep bar is **asymmetric on purpose**: wrongly deleting a real warning costs far more than
leaving a mediocre comment. When a judgment call is genuinely close, keep it and flag it in the
report rather than resolving it silently.

## Code comments

Code shows *how*. A comment earns its line only by carrying *why* — a non-obvious constraint, a
deliberate deviation, a gotcha, or a workaround with its expiry condition.

| # | Verdict | The comment… |
|---|---|---|
| 1 | **delete** | narrates the code, restates a signature, or marks a block ending |
| 2 | **delete** | is addressed to a diff reviewer, not a future reader — "fixed X", "updated to Y", "new in this PR". That belongs in the commit message |
| 3 | **delete or rewrite** | points at an ephemeral spec or section number. Encode the substance directly; a ticket or maintained README may stay as a breadcrumb |
| 4 | **trim** | carries a real *why* but over-explains it. Cut the mechanism, keep what a reader needs *at that line* |
| 5 | **delete** | describes code that is no longer there |
| 6 | **keep** | is a genuine constraint: an edge case, a cross-file sync pointer, data-literal semantics, a format contract, an upstream bug reference |

"Carries a real why" and "is worded minimally" are **independent judgments**. A rationale can be
entirely legitimate and still three times longer than it needs to be.

Never add comments, docstrings or type annotations to code this branch did not change.

## Markdown — docs, ADRs, READMEs

Same principle, different unit. The bar a paragraph must clear is: *would a reader make a wrong
decision without it?*

- **Conclusion first.** The answer, the decision, or the command goes in the first sentence. Build-up
  before the point is the most common form of doc bloat.
- **Tables, lists and diffs over prose** for anything comparative, sequential, or enumerable.
- **Delete what the code already says.** A doc restating a manifest's field list goes stale and
  competes with the manifest for authority. Link to it instead.
- **Say it once.** A fact stated in two pages has two chances to be wrong and one guarantee of
  drifting. Pick the page that owns it; the other links.
- **Cut the throat-clearing**: "It is important to note that", "In this section we will", "As
  mentioned above".

**Diagrams are not prose and are not subject to this pass.** A mermaid diagram that replaces three
paragraphs of component description is the outcome this rule wants, not a target for it. Prefer
adding one where a doc explains a flow or a relationship in words.

## Commit messages and PR bodies

- The subject carries the *why* in one line, under 70 characters.
- The body explains the reasoning that is not visible in the diff. It does not restate the file
  list — the diff and the file table already show what changed.
- No "this PR does X, Y and Z" recap of a table that appears directly below it.

## Report

Counts, plus anything a human should overrule:

```
prune: 11 comments deleted, 3 trimmed, 1 flagged
  flagged: infrastructure/base/foo/values.yaml:42 — reads as stale, but names an
           upstream issue I could not verify as closed
```

Also surface, separately from the counts:

- **code that needed a comment to be legible** — that is a refactor signal, not a comment win
- **deferral TODOs** you found, so they are a decision rather than a discovery six months out
