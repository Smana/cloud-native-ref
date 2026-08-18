# PR Body Template

Use this as the skeleton for both Create Mode and Update Mode. Fill every bracketed placeholder; drop sections that genuinely do not apply (never leave empty `## Heading` stubs).

```markdown
## 🔍 [type]

<!-- feat | fix | docs | refactor | perf | test | chore | ci | security -->

## 📝 Summary

<1–2 sentence summary focused on the WHY, not a file list>

## 📋 Design

<!-- When a design doc is detected, link it: -->
Design: [`<date>-<topic>-design.md`](../blob/main/docs/superpowers/specs/<date>-<topic>-design.md)
Plan: [`<date>-<topic>-plan.md`](../blob/main/docs/superpowers/plans/<date>-<topic>-plan.md)

<one line: which part of the plan this PR delivers>

<!-- When no design exists but one is recommended, replace the above block with the warning snippet below. -->

## 🎯 Changes

- <concise bullet, ≤10 words>
- <concise bullet, ≤10 words>
- <concise bullet, ≤10 words>

## 📊 Flow

<!-- Use the mermaid styling from references/mermaid-styles.md -->

```mermaid
flowchart LR
    upstream["<Component>"] --> new["<New piece>"]:::new
    new --> existing["<Existing piece>"]
    classDef new fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff
```

## 🗂️ Files

| File | Type | Summary |
|------|------|---------|
| <path> | <new\|modified\|removed> | <1-line summary> |

<!-- Max 10 rows. Group similar files. -->

<details><summary>Detailed changes</summary>

### <file>
- <bulleted detail>

</details>

## 🏷️ Labels

<suggested labels, e.g. composition, security, infrastructure>
```

## Design-recommendation warning

Use this when the diff is substantial but no design doc exists:

```markdown
## ⚠️ Design Recommendation

This PR contains changes that would benefit from a design document:
- **Detected type**: <composition | infrastructure | security | platform>
- **Affected paths**: <key paths>

Consider brainstorming a design first (see `CLAUDE.md` → *Development Workflow*)
so the approach is agreed and checked against the platform constitution
before implementation.
```

## Content rules

- **Title**: under 70 characters. Type prefix (e.g., `feat(crossplane): add QueueInstance composition`).
- **Summary**: WHY over WHAT. The file table already shows WHAT.
- **Mermaid**: 5–8 nodes max. Label every arrow. Use LR unless the content demands TB.
- **File table**: max 10 rows; group identical kinds.
- **Labels**: match existing repo labels; do not invent new ones.
