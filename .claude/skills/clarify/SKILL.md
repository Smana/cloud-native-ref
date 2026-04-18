---
name: clarify
description: Resolve [NEEDS CLARIFICATION] markers — present 2–3 structured options, append the chosen decision as a CL-N entry to clarifications.md, replace the marker in spec.md with the CL-N reference. Append-only — never overwrites prior deliberations.
when_to_use: |
  When the user says "clarify the spec", "resolve open questions",
  "help me decide", "walk me through the unknowns", "let's fill in NEEDS CLARIFICATION",
  or when a spec.md has one or more [NEEDS CLARIFICATION: ...] markers
  the user is working through.
disable-model-invocation: true
argument-hint: "[spec-dir|spec-file] — directory or spec.md path; omit for most-recent active spec"
paths: "docs/specs/**"
allowed-tools: Read, Edit, Glob
---

# Clarify Skill

Walk through unresolved design questions one at a time. **Decisions are durable**: each one becomes an append-only `CL-N` entry in `clarifications.md`, and the marker in `spec.md` is replaced with a reference like `See CL-3` (never with the inline answer). Future readers can always reconstruct *why* the decision was made.

## Workflow

### 1. Locate spec directory

If the user gave a directory, use it. If a `spec.md` path, use its parent. Otherwise pick the most-recently-modified active spec directory:

```bash
find docs/specs -name spec.md -not -path '*/done/*' -not -path '*/templates/*' -type f \
  | xargs ls -t 2>/dev/null | head -1 | xargs dirname
```

Required files: `spec.md`, `clarifications.md`. If `clarifications.md` is missing, copy `docs/specs/templates/clarifications.md` into the directory first.

### 2. Find the next unresolved marker

Use Grep with `-n` for line numbers. Pattern: `\[NEEDS CLARIFICATION: ([^\]]+)\]` in `spec.md` (and optionally `plan.md`). If zero, report and exit.

### 3. Determine the next CL-N

Read existing `## CL-<N>` headings in `clarifications.md`. Next ID = max(N) + 1. If none exist yet, start at `CL-1`.

### 4. Generate options (4-perspective framework)

Apply the framework in [`references/decision-framework.md`](references/decision-framework.md) — security, platform engineering, SRE, product. Always 2–3 options + a recommendation tied back to the constitution / existing patterns / the relevant SC-XXX.

Present in this fixed format:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CL-<N>: <verbatim question from marker>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Context: <2–3 sentences>

  | Option | Answer | Pros | Cons |
  |--------|--------|------|------|
  | A      | <ans>  | <p>  | <c>  |
  | B      | <ans>  | <p>  | <c>  |
  | C      | Custom | (user supplies)         |

  Recommendation: <A/B> — <one-line rationale>

Your choice (A/B/C or custom answer): _
```

A worked example lives in [`examples/clarification-session.md`](examples/clarification-session.md).

### 5. Persist the decision (two writes)

**(a) Append to `clarifications.md`** — new section at end of file, never edit prior entries:

```markdown
## CL-<N> — <YYYY-MM-DD> — <one-line question>

**Asked by**: <role / "Spec author">
**Context**: <text from step 4>

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | <answer> | <pros> | <cons> |
| B | <answer> | <pros> | <cons> |
| C | <answer> | <pros> | <cons> |

**Decision**: <Option letter + answer text>
**Rationale**: <why — tie to constitution / existing pattern / SC-XXX>
**Decided by**: <user input via /clarify, YYYY-MM-DD>
**References**: <ADR / vendor doc / similar spec>
```

**(b) Replace the marker in `spec.md`** with a reference:

```
Before: - [ ] [NEEDS CLARIFICATION: <question>]
After:  - [x] CL-<N> — <one-line question>
```

The "Resolved questions" list at the bottom of `spec.md` should also be updated to include the new `CL-<N> — <summary>` line.

### 6. Continue and report

After each resolution, print `Resolved <N>/<M>`. When all done:

```
All clarifications resolved in <spec_dir>.

Decisions logged:
  CL-1: <topic> → <answer>
  CL-2: <topic> → <answer>
  ...

Next:
  - Complete the 4-persona review checklist in plan.md
  - Run /validate to verify spec + plan + tasks completeness
  - Run /analyze for cross-artifact consistency
```

## Anti-patterns

- ❌ Inline `[CLARIFIED: ...]` in `spec.md`. Decisions belong in `clarifications.md`.
- ❌ Overwriting an earlier `CL-N` entry. If the decision changed, append a new `CL-M` that references and supersedes it.
- ❌ Recommending without applying the 4-perspective framework.

## Related skills

- `/spec` — creates the directory + 4 artifacts including `clarifications.md`
- `/spec-research` — pre-deliberation research that might surface canonical answers
- `/validate` — checks spec.md / plan.md / tasks.md / clarifications.md together
- `/analyze` — cross-artifact consistency
