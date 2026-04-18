---
name: analyze
description: Cross-artifact consistency check for an SDD spec directory. Detects coverage gaps (FR/SC with no tasks), ambiguous adjectives in success criteria, constitution violations, duplicate requirements, plan/spec terminology drift, and unresolved clarifications. Inspired by Spec Kit's /speckit.analyze.
when_to_use: |
  When the user says "analyze the spec", "consistency check", "is this spec coherent",
  "check coverage", "spec gap analysis", "find drift between spec and plan",
  or before approving a spec for implementation. Run after /clarify and /validate.
disable-model-invocation: true
argument-hint: "[spec-dir] — directory or any artifact path; omit for most-recent active spec"
paths: "docs/specs/**"
allowed-tools: Read, Grep, Glob, Bash(grep:*), Bash(find:*)
---

# Analyze Skill

Run this before implementation to catch problems that single-artifact validation misses: requirements that no task implements, plan designs not traceable to spec requirements, vague success criteria, terminology drift between artifacts, and constitution violations.

## Workflow

### 1. Locate the spec directory

Same as `/validate`: accept a directory, a path to any artifact inside it, or pick the most-recently-modified active spec.

### 2. Load all 4 artifacts (read-only)

`spec.md`, `plan.md`, `tasks.md`, `clarifications.md`. If any is missing, report and exit (the spec is structurally incomplete — `/validate` already handles that).

### 3. Run cross-artifact analyses

Apply each rule in [`references/analyze-rules.md`](references/analyze-rules.md). Categories:

| Category | Severity | Examples |
|---|---|---|
| **Coverage** | HIGH | FR-XXX with zero matching tasks; SC-XXX with no verification path |
| **Ambiguity** | MEDIUM | SC-XXX uses "fast", "scalable", "secure" without a measurable threshold |
| **Constitution** | CRITICAL | Plan proposes a resource without `xplane-*` prefix; mutates a KCL dict; missing CiliumNetworkPolicy in plan |
| **Drift** | MEDIUM | spec.md uses "Queue", plan.md uses "Topic" — same concept, different name |
| **Duplication** | MEDIUM | Two FR-XXX entries that paraphrase each other |
| **Stale clarification** | LOW | spec.md references `CL-N` that doesn't exist in clarifications.md |
| **Open question** | HIGH | Unresolved `[NEEDS CLARIFICATION:]` in spec.md or plan.md |

### 4. Render the analysis report

Use this fixed format:

```
╔════════════════════════════════════════════════════════════════╗
║  Cross-Artifact Analysis: <spec-dir>                          ║
╚════════════════════════════════════════════════════════════════╝

| ID  | Category      | Severity | Location              | Summary                          | Recommendation                |
|-----|---------------|----------|-----------------------|----------------------------------|-------------------------------|
| A1  | Coverage      | HIGH     | spec.md FR-002        | No matching task in tasks.md     | Add T00N implementing FR-002  |
| A2  | Ambiguity     | MEDIUM   | spec.md SC-001        | "fast" without metric            | Specify p95 latency target    |
| C1  | Constitution  | CRITICAL | plan.md L42           | Resource missing xplane- prefix  | Rename `harbor-bucket` → `xplane-harbor-bucket` |
| D1  | Drift         | MEDIUM   | spec.md / plan.md     | "Queue" vs "Topic"                | Standardize on one term       |

────────────────────────────────────────────────────────────────
Coverage Summary

| Requirement | Has task? | Task IDs | Notes |
|-------------|-----------|----------|-------|
| FR-001      | ✅        | T003, T005 |     |
| FR-002      | ❌        | —        | Missing |
| FR-003      | ✅        | T007     |       |

| Success Criterion | Verification path | Notes |
|-------------------|-------------------|-------|
| SC-001            | example deploy + AWS API call | covered |
| SC-002            | metric query (cache_evictions_total) | covered |

────────────────────────────────────────────────────────────────
Verdict: BLOCK | PASS WITH WARNINGS | PASS

CRITICAL findings: <count>
HIGH findings:     <count>
MEDIUM findings:   <count>
LOW findings:      <count>

Next:
  - <highest-priority remediation>
  - Re-run /analyze after fixes
```

### 5. Verdict logic

- **BLOCK**: any CRITICAL finding remains. Implementation must not start.
- **PASS WITH WARNINGS**: HIGH or MEDIUM remain. Document trade-offs in `clarifications.md` (new CL-N) before implementing, or fix them.
- **PASS**: LOW or none.

## Anti-patterns to avoid

- ❌ Re-deriving rules from scratch each invocation. Use `references/analyze-rules.md`.
- ❌ Suggesting fixes that violate the constitution (e.g., propose IRSA over Pod Identity).
- ❌ Inventing fake findings to look thorough — empty result is a valid output for a clean spec.
- ❌ Modifying any artifact. `/analyze` is read-only.

## Related skills

- `/validate` — single-artifact structural check (run first)
- `/clarify` — resolve `[NEEDS CLARIFICATION]` and convert to CL-N (run before `/analyze`)
- `/spec-research` — gather data that might preempt findings (run before filling spec)
- `/create-pr` — uses analyze verdict in its spec-readiness gate
