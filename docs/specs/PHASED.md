# Phased Specs

For features that genuinely need to ship across multiple PRs (the QueueInstance pattern from issues #1300–1304: prereqs → composition → packaging → validation → docs), keep one spec directory but break execution into sub-phases.

> Use sparingly. Most composition work fits a single spec; introducing phases for small features adds bureaucracy without payoff.

## Layout

```
docs/specs/005-queueinstance/
├── spec.md             ← One set of requirements for the whole feature
├── plan.md             ← Overall design + phase map + cross-phase tasks
├── clarifications.md   ← Cross-phase decisions
└── phases/
    ├── 1-prereqs/
    │   └── plan.md     ← Phase-local design + Tasks section
    ├── 2-composition/
    │   └── plan.md
    ├── 3-packaging/
    │   └── plan.md
    └── ...
```

Each phase directory has a thin `plan.md` covering only that phase's design + tasks. The root `plan.md` keeps the high-level phase map.

## GitHub issues

- **One issue per phase**, matching the existing `[Phase N]` naming convention.
- All phase issues `Depends on #<parent-spec-issue>` for traceability.
- Apply phase-specific labels: `phase:1-prereqs`, `phase:2-composition`, etc.
- The parent spec issue stays open until **all** phase PRs merge.

## Phase map in root plan.md

Add this table to the root `plan.md`:

```markdown
## Phases

| Phase | Scope | Depends on | Issue | Status |
|-------|-------|------------|-------|--------|
| 1-prereqs       | <scope> | —              | #1300 | ✅ done |
| 2-composition   | <scope> | 1-prereqs      | #1301 | 🚧 in progress |
| 3-packaging     | <scope> | 2-composition  | #1302 | ⏸ pending |
| 4-validation    | <scope> | 3-packaging    | #1303 | ⏸ pending |
| 5-documentation | <scope> | 4-validation   | #1304 | ⏸ pending |
```

## Per-phase PRs

- Each phase PR references its phase directory in the body (e.g., `docs/specs/005-queueinstance/phases/2-composition/`).
- The archive workflow generates a `SUMMARY.md` per phase on merge.
- The parent spec is **not** archived until all phases are done.

## When the last phase merges

- Manually move the parent spec to `docs/specs/done/YYYY-Qn/005-queueinstance/`, preserving the `phases/` subdirectory and all per-phase SUMMARYs.
- Optionally write a top-level `LEARNINGS.md` capturing cross-phase retrospective notes.

## Decision: do you really need phases?

Use phases when **all three** are true:

1. The work cannot ship in a single PR (size, dependencies, or risk profile).
2. Each phase has a clear, independently-verifiable acceptance criterion.
3. Phases can be sequenced (later phases depend on earlier ones being live).

If only #1 applies, prefer splitting into multiple **separate specs** that depend on each other. Phasing inside one spec only earns its complexity when the work is genuinely a single feature.
