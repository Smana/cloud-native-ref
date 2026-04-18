---
name: validate
description: Validate a spec file for completeness (required sections, resolved clarifications, issue link, constitution reference, review checklist ≥75%, requirements/SC counts, structured tasks) and suggest fixes.
when_to_use: |
  When the user says "validate my spec", "is the spec ready",
  "check if this spec is complete", "pre-flight the spec",
  "spec quality check", or wants confidence a spec is ready for implementation.
disable-model-invocation: true
argument-hint: "[spec-file] — path to spec.md, or omit for most-recently-modified active spec"
paths: "docs/specs/**"
allowed-tools: Bash(./scripts/validate-spec.sh:*), Read, Glob
---

# Validate Skill

Run the spec validator and present results with actionable remediation suggestions.

## Workflow

### 1. Find the target spec

If the user named a file, use it. Otherwise pick the most-recently-modified active spec:

```bash
find docs/specs -name spec.md -not -path '*/done/*' -not -path '*/templates/*' -type f \
  | xargs ls -t 2>/dev/null | head -1
```

### 2. Run the validator

```bash
./scripts/validate-spec.sh "$SPEC_FILE"
```

The script checks:
1. Required sections (Summary / Problem / User Stories / Requirements / Success Criteria / Design / Tasks)
2. No unresolved `[NEEDS CLARIFICATION: ...]` markers
3. GitHub issue link present
4. Constitution reference present
5. No unfilled placeholders (`SPEC-XXX`, `YYYY-MM-DD`, `[Title]`, ...)
6. Review checklist ≥75% complete (error if <75%)
7. ≥2 `FR-XXX` entries (warning if fewer)
8. ≥2 `SC-XXX` entries (warning if fewer)
9. Tasks use structured IDs (`T001`, `T002`, ...)

### 3. Present results

Use this layout:

```
╔════════════════════════════════════════════════════════════════╗
║  Spec Validation: <path>                                       ║
╚════════════════════════════════════════════════════════════════╝

✅ <passed check>
⚠️  <warning>
❌ <error>
   → <one-line fix>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Result: PASSED | PASSED with N warnings | FAILED with N errors
```

For each failure or warning, cite the canonical remediation from [`references/error-suggestions.md`](references/error-suggestions.md). Load it on invocation.

### 4. Suggest next step

- If errors remain → block with the most impactful fix.
- If only warnings → recommend addressing before implementation, but allow proceeding.
- If all green → suggest `/create-pr` (or `/analyze` once that skill exists).

## Integration

- `/spec` — creates the spec this validates
- `/clarify` — resolves marker errors
- `/create-pr` — requires validate to pass

## Related

- Validator script: [`scripts/validate-spec.sh`](../../../scripts/validate-spec.sh)
- Error templates: [`references/error-suggestions.md`](references/error-suggestions.md)
