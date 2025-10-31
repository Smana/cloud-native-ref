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
   - Type, 1-2 sentence summary, 3 key changes (max 10 words each)
   - Mermaid flowchart (5-7 nodes, main flow only)
   - File table (max 10 files, grouped)
   - Detailed changes (concise bullets)
   - Labels

3. **Update**:
   ```bash
   gh pr edit $PR --body "..."
   ```

4. **Output**: "Updated PR #X" with URL

## Template
```markdown
## 🔍 [type]
## 📝 Summary
[1-2 sentences max]
## 🎯 Changes
- Change 1 (concise)
- Change 2 (concise)
- Change 3 (concise)
## 📊 Flow
```mermaid
flowchart LR
    comp1["Component"]
    comp2["New"]:::new
    comp3["Modified"]:::modified
    comp1 --> comp2 --> comp3
    classDef new fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff
    classDef modified fill:#c2410c,stroke:#f97316,stroke-width:3px,color:#fff
```
## 🗂️ Files
| File | Type | Summary |
|------|------|---------|
[max 10 rows]
<details><summary>Details</summary>
### file
- brief changes
</details>
## 🏷️ Labels
[labels]
```

## Styling
- New: `fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff`
- Modified: `fill:#c2410c,stroke:#f97316,stroke-width:3px,color:#fff`
- Removed: `fill:#991b1b,stroke:#dc2626,stroke-width:3px,color:#fff,stroke-dasharray:5 5`
