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
   - 1-2 sentence summary
   - 3 key changes (bullet points, max 10 words each)
   - Mermaid flowchart (LR format, 5-7 nodes max, show main flow only)
   - File table (max 10 files, group similar changes)
   - Detailed changes in collapsible section (concise bullet points)
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
    comp2["Service"]:::new
    comp1 --> comp2
    classDef new fill:#1e3a8a,stroke:#3b82f6,stroke-width:3px,color:#fff
```

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
[mermaid flowchart - simple]
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
