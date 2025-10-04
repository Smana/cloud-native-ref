---
allowed-tools: Bash(gh:*), Bash(git:*), Edit, Write, Read
argument-hint: <pr-number>
description: AI-powered code improvements for a Pull Request with automatic fix suggestions
---

# Claude Code Command: Improve Pull Request

This command analyzes a Pull Request and provides specific, actionable code improvements, similar to pr-agent's `/improve` command. It can optionally apply the improvements directly.

## Instructions

**IMPORTANT**: Use context7 to understand the codebase patterns, best practices, and architectural conventions before suggesting improvements. This ensures recommendations align with project standards.

### 1. Fetch PR Information and Checkout Branch

```bash
# Get PR details
PR_INFO=$(gh pr view $ARGUMENTS --json headRefName,baseRefName,files,title)
HEAD_BRANCH=$(echo $PR_INFO | jq -r '.headRefName')

# Checkout the PR branch
git fetch origin
git checkout $HEAD_BRANCH
git pull origin $HEAD_BRANCH

# Get the diff
gh pr diff $ARGUMENTS
```

### 2. Analyze for Improvements

Scan the code for opportunities to improve:

**Code Quality**:
- Extract duplicate code into functions
- Simplify complex conditionals
- Improve variable/function naming
- Add error handling
- Reduce nesting depth
- Apply SOLID principles

**Performance**:
- Optimize algorithms
- Reduce database queries
- Add caching where appropriate
- Lazy load resources
- Parallel processing opportunities

**Readability**:
- Add clarifying comments
- Break down large functions
- Improve code organization
- Use descriptive names
- Add type hints/annotations

**Best Practices**:
- Follow language idioms
- Use modern syntax
- Apply design patterns
- Improve error messages
- Add logging where helpful

### 3. Generate Improvement Suggestions

For each file, create a structured improvement report:

```markdown
# 🚀 Code Improvements for PR #$ARGUMENTS

## Summary
Found **[count]** improvement opportunities across **[count]** files

## 📈 Improvements by Category

### 🎨 Code Quality ([count] suggestions)
### ⚡ Performance ([count] suggestions)
### 📖 Readability ([count] suggestions)
### ✨ Best Practices ([count] suggestions)

---

## File-by-File Improvements

### 📄 path/to/file1.ext

#### 1. Extract Duplicate Logic (Code Quality)
**Priority**: High
**Lines**: 45-60, 78-92
**Impact**: Reduces code duplication by 30 lines

**Current Code**:
```language
[show current duplicated code]
```

**Improved Code**:
```language
[show refactored code with extracted function]
```

**Benefits**:
- Reduces duplication
- Easier to maintain
- Single source of truth

---

#### 2. Optimize Database Query (Performance)
**Priority**: High
**Lines**: 103-107
**Impact**: Reduces N+1 queries

**Current Code**:
```language
[show current code with N+1 query]
```

**Improved Code**:
```language
[show optimized code with eager loading]
```

**Benefits**:
- Reduces database calls from N to 1
- Improves response time
- Lower database load

---

### 📄 path/to/file2.ext

[Continue with similar structure for each file]

---

## 🎯 Implementation Priority

### 🔴 High Priority (Should implement now)
1. [File:Line] - [Issue] - [Estimated time: Xs]
2. [File:Line] - [Issue] - [Estimated time: Xs]

### 🟡 Medium Priority (Consider for this PR)
1. [File:Line] - [Issue] - [Estimated time: Xs]
2. [File:Line] - [Issue] - [Estimated time: Xs]

### 🟢 Low Priority (Future enhancement)
1. [File:Line] - [Issue] - [Estimated time: Xs]
2. [File:Line] - [Issue] - [Estimated time: Xs]

---

## 📊 Impact Summary

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Lines of Code | [count] | [count] | -X% |
| Cyclomatic Complexity | [avg] | [avg] | -X% |
| Code Duplication | [count] duplicates | [count] duplicates | -X% |
| Function Length (avg) | [count] lines | [count] lines | -X% |

---

## 🔧 Auto-Apply Available

I can automatically apply these improvements. Would you like me to:
- [ ] Apply all high-priority improvements
- [ ] Apply specific improvements (specify which)
- [ ] Show me the changes first (don't apply yet)
```

### 4. Ask User for Action

Present options:
1. **Apply high-priority improvements automatically**
2. **Apply specific improvements** (user selects)
3. **Show changes without applying** (review first)
4. **Post as PR comment** (for team review)

### 5. Apply Improvements (if requested)

If user chooses to apply:

```bash
# For each improvement:
# 1. Use Edit tool to apply the change
# 2. Verify syntax is correct
# 3. Track what was changed

# After all changes:
git add .
git commit -m "🚀 improve: apply AI-suggested code improvements

- Extract duplicate logic in file1
- Optimize database queries in file2
- Improve error handling in file3
- Add clarifying comments

Applied by Claude Code /improve-pr command"

git push origin $HEAD_BRANCH
```

### 6. Update PR with Summary

```bash
# Post a comment summarizing the improvements
gh pr comment $ARGUMENTS --body "[Generated improvement summary]"
```

## Improvement Patterns

### Code Smells to Fix
- **Long Method**: Break into smaller functions
- **Large Class**: Split responsibilities
- **Long Parameter List**: Use object/config
- **Duplicate Code**: Extract to shared function
- **Dead Code**: Remove unused code
- **Magic Numbers**: Use named constants
- **Nested Conditionals**: Early returns/guard clauses

### Performance Optimizations
- **N+1 Queries**: Eager loading
- **Inefficient Loops**: Use better algorithms
- **Synchronous I/O**: Use async/parallel
- **No Caching**: Add memoization
- **Large Payloads**: Paginate/stream

### Best Practices
- **No Error Handling**: Add try-catch
- **Poor Naming**: Use descriptive names
- **No Type Safety**: Add types/interfaces
- **Hardcoded Values**: Use configuration
- **No Logging**: Add observability

## Safety Checks

Before applying any improvement:
1. ✅ Verify syntax is valid
2. ✅ Ensure tests still pass (if available)
3. ✅ Preserve original functionality
4. ✅ Check no breaking changes introduced
5. ✅ Validate code compiles/runs

## Output Guidelines

**Be Specific**:
- Include exact line numbers
- Show before/after code
- Explain why the improvement helps

**Be Practical**:
- Focus on high-impact changes
- Consider implementation effort
- Prioritize based on value

**Be Safe**:
- Don't break existing functionality
- Maintain backward compatibility
- Preserve test coverage

## Example Usage

```
/improve-pr 123
/improve-pr 456
```

---

**Remember**: Quality over quantity. A few high-impact improvements are better than many minor tweaks. Always preserve functionality while improving code quality.
