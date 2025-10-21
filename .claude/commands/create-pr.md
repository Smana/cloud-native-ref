---
allowed-tools: Bash(git:*), Bash(gh:*)
argument-hint: [base-branch] (optional, defaults to main)
description: Create a detailed Pull Request with AI-generated description, mermaid diagram, and walkthrough
---

# Create Pull Request

Generate and create a comprehensive PR with description, diagram, and file walkthrough.

## Steps

1. **Gather info** (run in parallel):
   - `git log origin/$BASE..HEAD --oneline`
   - `git diff origin/$BASE...HEAD --stat`
   - `git diff origin/$BASE...HEAD`

2. **Generate description** with:
   - Type: feat/fix/docs/refactor/perf/test/chore/ci/security
   - 2-3 sentence summary
   - 5 key changes (bullet points)
   - Mermaid flowchart (LR format, 8-10 nodes max, show component flow)
   - File table with change types
   - Detailed changes in collapsible section
   - Suggested labels

3. **Create PR**:
   ```bash
   git push -u origin $(git branch --show-current)
   gh pr create --base ${BASE:-main} --title "..." --body "..."
   ```

4. **Output**: URL only

## Mermaid Format
```mermaid
flowchart LR
    comp1["Component"]
    comp2["New Service"]:::new
    comp1 -- "action" --> comp2
    classDef new fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff
```

## Template
```markdown
## 🔍 Type: [type]
## 📝 Summary
[2-3 sentences]
## 🎯 Changes
- Change 1
- Change 2
## 📊 Diagram
[mermaid flowchart]
## 🗂️ Files
| File | Type | Description |
|------|------|-------------|
[table rows]
<details><summary>Details</summary>
### file
- changes
</details>
## 🏷️ Labels
[labels]
```
