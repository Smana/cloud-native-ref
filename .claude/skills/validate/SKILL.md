---
name: validate
description: Validate a spec directory end-to-end — structural completeness, FR/SC counts, falsifiable success criteria, FR coverage in plan tasks, no stale CL-N references, and constitution compliance. Single gate before implementation.
when_to_use: |
  When the user says "validate my spec", "is the spec ready",
  "check if this spec is complete", "pre-flight the spec",
  "spec quality check", "analyze the spec", or wants confidence
  before implementation begins.
disable-model-invocation: true
argument-hint: "[spec-dir|spec-file] — directory or any artifact path; omit for most-recent active spec"
paths: "docs/specs/**"
allowed-tools: Bash(./scripts/validate-spec.sh:*), Read, Grep, Glob
---

# Validate Skill

Single quality gate that runs the spec validator and surfaces both structural and cross-artifact issues.

## Workflow

### 1. Find the target spec directory

```bash
find docs/specs -name spec.md -not -path '*/done/*' -not -path '*/templates/*' -type f \
  | xargs ls -t 2>/dev/null | head -1 | xargs dirname
```

### 2. Run the validator script

```bash
./scripts/validate-spec.sh "$SPEC_DIR"
```

The script handles structural + grep-detectable checks:
- All 3 artifacts present (`spec.md`, `plan.md`, `clarifications.md`)
- `spec.md`: required sections, GitHub issue link, FR-XXX / SC-XXX counts ≥ 2, vague-adjective detection
- `plan.md`: Design + Tasks + Review Checklist sections; checklist ≥ 75%; T001-style task IDs
- `clarifications.md`: append-only `## CL-N` format, no duplicate IDs
- **Cross-artifact**: every FR-XXX referenced in plan.md tasks (coverage gap detection); CL-N references in spec/plan resolve to entries in clarifications.md
- No unresolved `[NEEDS CLARIFICATION:]` or forbidden inline `[CLARIFIED:]` (decisions must live in clarifications.md)

### 3. Apply semantic cross-artifact rules

After the script reports, apply the rules in [`references/cross-artifact-rules.md`](references/cross-artifact-rules.md) — these are deeper checks Claude reasons about (not greppable):

- **Constitution violations** (CRITICAL): `xplane-*` prefix, KCL mutation pattern, missing `CiliumNetworkPolicy`, missing security context, hardcoded credentials, IRSA mention, missing resource limits
- **Drift**: terminology mismatch between `spec.md` and `plan.md`; resources in plan that aren't traced to an FR
- **Duplication**: similar FRs / SCs that should be merged
- **Ambiguity**: vague enumerations (`etc.`), SCs without measurable verification path

### 4. Present results

```
╔════════════════════════════════════════════════════════════════╗
║  Spec Validation: <path>                                       ║
╚════════════════════════════════════════════════════════════════╝

[script output: structural + coverage checks]

Cross-artifact findings (semantic):
| ID  | Category      | Severity | Location              | Recommendation |
|-----|---------------|----------|-----------------------|----------------|
| C1  | Constitution  | CRITICAL | plan.md L42           | Rename to xplane-* |
| D1  | Drift         | MEDIUM   | spec.md / plan.md     | Standardize term |

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Verdict: BLOCK | PASS WITH WARNINGS | PASS
```

For structural failures, cite the canonical remediation from [`references/error-suggestions.md`](references/error-suggestions.md).

### 5. Suggest next step

- **BLOCK** (any CRITICAL constitution violation or script error) → fix the most impactful issue, re-run.
- **PASS WITH WARNINGS** → either fix or document the trade-off as a new `CL-N` in `clarifications.md`.
- **PASS** → proceed with implementation, then `/create-pr`.

## Integration

- `/spec` — creates the spec this validates
- `/clarify` — resolves marker errors
- `/create-pr` — requires `/validate` to pass

## Related

- Validator script: [`scripts/validate-spec.sh`](../../../scripts/validate-spec.sh)
- Error templates: [`references/error-suggestions.md`](references/error-suggestions.md)
- Cross-artifact rules: [`references/cross-artifact-rules.md`](references/cross-artifact-rules.md)
