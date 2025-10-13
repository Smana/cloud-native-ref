---
allowed-tools: Bash(git:*), Bash(gh:*)
argument-hint: [base-branch] (optional, defaults to main)
description: Create a detailed Pull Request with AI-generated description, mermaid diagram, and walkthrough
---

# Claude Code Command: Create Pull Request

This command creates a comprehensive Pull Request with a detailed description similar to pr-agent, including:
- PR type classification
- Summary of changes
- Mermaid diagram (flowchart LR format showing architecture/flow)
- File-by-file walkthrough
- Suggested labels

## Instructions

**IMPORTANT**: Use context7 to search for relevant documentation, codebase patterns, and architectural decisions before generating the PR description. This ensures accurate and contextual descriptions.

You MUST follow these steps in order:

### 1. Gather Information

First, use context7 to understand the codebase context, then run these commands in parallel to understand the PR changes:
- `git status` - Check current branch and uncommitted changes
- `git log origin/$BASE_BRANCH..HEAD --oneline` - Get commit history (where $BASE_BRANCH is the first argument or "main")
- `git diff origin/$BASE_BRANCH...HEAD --stat` - Get file statistics
- `git diff origin/$BASE_BRANCH...HEAD` - Get full diff

### 2. Analyze Changes

Based on the diff, determine:

**PR Type** (choose ONE):
- `feat` - New feature
- `fix` - Bug fix
- `docs` - Documentation changes
- `refactor` - Code refactoring
- `perf` - Performance improvements
- `test` - Test additions/changes
- `chore` - Maintenance tasks
- `ci` - CI/CD changes
- `security` - Security improvements

**Impact Areas** (identify which components/modules are affected)

### 3. Generate PR Description

Create a PR description with the following structure:

```markdown
## 🔍 PR Type: [type]

## 📝 Summary
[2-3 sentence concise summary of what this PR does and why]

## 🎯 Changes Overview
[Bullet points of main changes, max 5 items]

## 📊 Architecture Diagram

```mermaid
flowchart LR
    [Create a horizontal flowchart showing:
    - Main components affected (as nodes with descriptions in quotes)
    - Relationships between them (with labeled arrows)
    - New components added (if any)

    Format:
    nodeID1["Component/Function Name"]
    nodeID2["Another Component"]
    nodeID1 -- "relationship/action" --> nodeID2
    ]
```

## 🗂️ File Changes Walkthrough

| File | Change Type | Description |
|------|-------------|-------------|
| path/to/file1 | Modified/Added/Deleted | Brief description of what changed |
| path/to/file2 | Modified/Added/Deleted | Brief description of what changed |

<details>
<summary><b>Detailed Changes</b></summary>

### path/to/file1
- [Specific change 1]
- [Specific change 2]

### path/to/file2
- [Specific change 1]
- [Specific change 2]

</details>

## 🏷️ Suggested Labels
[Comma-separated list: e.g., enhancement, infrastructure, security, needs-review]

## ✅ Testing
[If tests were added/modified, describe what's covered]

## 📚 Additional Context
[Any important notes, breaking changes, migration steps, etc.]
```

### 4. Create the Pull Request

**IMPORTANT**: Before creating the PR:
1. Ensure all changes are committed
2. Push the current branch to origin
3. Use `gh pr create` with the generated description

Execute these commands:

```bash
# Get current branch name
CURRENT_BRANCH=$(git branch --show-current)

# Get base branch (from $ARGUMENTS or default to main)
BASE_BRANCH="${$ARGUMENTS:-main}"

# Push current branch if needed
git push -u origin $CURRENT_BRANCH

# Create PR with the generated description
gh pr create \
  --base $BASE_BRANCH \
  --head $CURRENT_BRANCH \
  --title "[Generated title based on commits and changes]" \
  --body "[The full markdown description you generated above]"
```

### 5. Output PR URL

After successful creation, output:
- ✅ PR created successfully
- 🔗 PR URL (from gh command output)
- 📋 Summary of what was included

## Guidelines for Quality

**Mermaid Diagram**:
- Keep it simple and readable (max 8-10 nodes)
- Use meaningful node IDs (camelCase)
- Always quote node descriptions: `nodeId["Description"]`
- Show data flow or component interaction
- Use clear arrow labels

**File Walkthrough**:
- Group related file changes
- Be concise but informative
- Highlight breaking changes
- Note new dependencies or configuration

**Summary**:
- Start with the "what" and "why"
- Mention impact/benefits
- Keep under 100 words

## Error Handling

If any of these occur:
- No changes to commit → Tell user to commit first
- Already on main/base branch → Ask user to create a feature branch
- No remote branch → Explain push is needed
- gh CLI not authenticated → Guide through `gh auth login`

## Example Usage

```
/create-pr main
/create-pr develop
/create-pr
```

---

**Remember**: Generate a comprehensive, professional PR description that helps reviewers understand the changes quickly and thoroughly. The mermaid diagram should provide visual context, and the walkthrough should guide reviewers through the changes logically.
