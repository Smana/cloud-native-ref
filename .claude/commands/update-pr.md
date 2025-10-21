---
allowed-tools: Bash(gh:*), Bash(git:*)
argument-hint: <pr-number>
description: Update PR description with AI-generated mermaid diagram and detailed walkthrough
---

# Update Pull Request

Update existing PR with comprehensive description, diagram, and walkthrough.

## Steps

1. **Fetch PR** (run in parallel):
   - `gh pr view $PR --json number,title,files,additions,deletions`
   - `gh pr diff $PR`

2. **Generate description** (same format as create-pr):
   - Type, summary, 5 key changes
   - Mermaid flowchart with styling for new/modified components
   - File table + detailed changes
   - Labels

3. **Update**:
   ```bash
   gh pr edit $PR --body "..."
   ```

4. **Output**: "Updated PR #X" with URL

## Template
```markdown
## 🔍 Type: [type]
## 📝 Summary
[2-3 sentences]
## 🎯 Changes
- Change 1
- Change 2
## 📊 Diagram
```mermaid
flowchart LR
    comp1["Existing"]
    comp2["New"]:::new
    comp3["Modified"]:::modified
    comp1 --> comp2 --> comp3
    classDef new fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff
    classDef modified fill:#c2410c,stroke:#f97316,stroke-width:3px,color:#fff
```
## 🗂️ Files
| File | Type | Lines | Description |
|------|------|-------|-------------|
[rows]
<details><summary>Details</summary>
### file
- changes
</details>
## 🏷️ Labels
[labels]
```

## Styling
- New (dark blue): `fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff`
- Modified (dark orange): `fill:#c2410c,stroke:#f97316,stroke-width:3px,color:#fff`
- Removed (red): `fill:#991b1b,stroke:#dc2626,stroke-width:3px,color:#fff,stroke-dasharray:5 5`
