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
    classDef new fill:#90EE90,stroke:#228B22
    classDef modified fill:#FFD700,stroke:#FF8C00
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
- Green (new): `fill:#90EE90,stroke:#228B22`
- Yellow (modified): `fill:#FFD700,stroke:#FF8C00`
- Red (removed): `fill:#FFB6C1,stroke:#DC143C,stroke-dasharray:5 5`
