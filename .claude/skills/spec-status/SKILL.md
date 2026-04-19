---
name: spec-status
description: Show a pipeline overview of all specifications — counts of Draft / Implementing / Done, plus stale-spec detection.
when_to_use: |
  When the user says "spec status", "where are we on specs", "spec pipeline",
  "what specs are in flight", "show SDD overview", "any stale specs",
  "what's in progress", or asks for a summary of ongoing spec work.
disable-model-invocation: true
allowed-tools: Bash(find:*), Bash(grep:*), Bash(gh:*), Read
---

# Spec Status Skill

Display a pipeline overview of all specifications. Counts are pre-computed via dynamic context injection so Claude reasons on fresh state.

## Live pipeline state

- **Active spec files**: !`find docs/specs -name spec.md -not -path '*/done/*' -not -path '*/templates/*' -type f 2>/dev/null | sort`
- **Done specs (all)**: !`find docs/specs/done -name spec.md -type f 2>/dev/null | wc -l`
- **Done this quarter**: !`Q=$(( ($(date +%m) - 1) / 3 + 1 )); find "docs/specs/done/$(date +%Y)-Q${Q}" -name spec.md -type f 2>/dev/null | wc -l`
- **Stale active specs (>14 days unchanged)**: !`find docs/specs -name spec.md -not -path '*/done/*' -not -path '*/templates/*' -mtime +14 -type f 2>/dev/null`
- **Issues by label**:
  - Draft: !`gh issue list --label spec:draft --state open --json number,title --jq 'length' 2>/dev/null || echo "n/a"`
  - Implementing: !`gh issue list --label spec:implementing --state open --json number,title --jq 'length' 2>/dev/null || echo "n/a"`

## Your task

Render the pipeline overview the user sees.

### 1. Parse each active spec file

For every file in the **Active spec files** list above, extract the `**Status**:` line (one of: `draft`, `in-review`, `approved`, `implementing`, `done`).

### 2. Group specs

| Category    | Spec statuses                  |
|-------------|--------------------------------|
| Draft       | `draft`, `in-review`           |
| Implementing| `approved`, `implementing`     |
| Done        | (count from pre-computed done) |

### 3. Render

```
╔═══════════════════════════════════════════════════════════════╗
║  Spec Pipeline Status                                         ║
╚═══════════════════════════════════════════════════════════════╝

  Stage          Count   Specs
  ────────────────────────────────────────────────────────────
  Draft            N     <slug-list>
  Implementing     N     <slug-list>
  Done            NN     (archived in docs/specs/done/)
                         (NN this quarter)

⚠️  Stale (>14 days unchanged):
  → <slug>  (last modified: <date>)
```

If the stale list is empty, omit that section.
If GitHub issue counts differ from file counts, flag the drift (label desync).

### 4. Suggest next action

- If there are drafts with unresolved `[NEEDS CLARIFICATION]` markers → suggest `/clarify`.
- If there are specs whose review checklist is incomplete → suggest `/validate`.
- If there are stale specs → suggest closing or resuming.

## Related skills

- `/spec` — create a new specification
- `/clarify` — resolve clarification markers
- `/validate` — check spec completeness
- `/create-pr` — create PR that auto-references spec
