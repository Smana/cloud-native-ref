---
allowed-tools: Bash(gh:*), Bash(git:*)
argument-hint: <pr-number>
description: AI-powered code review of a Pull Request with security, best practices, and improvement suggestions
---

# Claude Code Command: Review Pull Request

This command performs a comprehensive AI-powered review of a Pull Request, similar to pr-agent's `/review` command.

## Instructions

**IMPORTANT**: Use context7 to understand the codebase architecture, coding standards, and security requirements before reviewing. This provides context for better review quality.

You MUST follow these steps:

### 1. Fetch PR Information

```bash
# Get PR details
gh pr view $ARGUMENTS --json title,body,headRefName,baseRefName,files,additions,deletions,commits

# Get PR diff
gh pr diff $ARGUMENTS

# Get PR checks status
gh pr checks $ARGUMENTS
```

### 2. Analyze the Code

Review the diff for:
- **Security issues**: SQL injection, XSS, secrets in code, insecure dependencies
- **Best practices**: Code style, naming conventions, error handling
- **Performance**: Inefficient algorithms, N+1 queries, memory leaks
- **Testing**: Missing tests, untested edge cases
- **Documentation**: Missing comments, outdated docs
- **Maintainability**: Code complexity, duplication, coupling

### 3. Generate Review Report

Create a structured review in this format:

```markdown
# 🔍 PR Review: [PR Title]

## 📊 Overview
- **Files Changed**: [count]
- **Lines Added**: [count]
- **Lines Deleted**: [count]
- **Overall Assessment**: ⭐⭐⭐⭐⭐ (1-5 stars)

## ✅ Strengths
- [Positive observation 1]
- [Positive observation 2]
- [Positive observation 3]

## 🔴 Critical Issues
> Issues that MUST be fixed before merging

| Severity | File | Line | Issue | Suggestion |
|----------|------|------|-------|------------|
| 🔴 High | path/to/file | L42 | [Issue description] | [How to fix] |

## 🟡 Warnings
> Issues that SHOULD be addressed

| Severity | File | Line | Issue | Suggestion |
|----------|------|------|-------|------------|
| 🟡 Medium | path/to/file | L15 | [Issue description] | [How to fix] |

## 💡 Suggestions
> Nice-to-have improvements

<details>
<summary><b>Code Quality Improvements</b></summary>

### path/to/file
**Line X-Y**
```diff
- [current code]
+ [improved code]
```
**Reason**: [Explanation]

</details>

## 🧪 Testing Coverage
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Edge cases covered
- [ ] Error handling tested

**Missing Coverage**:
- [Area 1 that needs tests]
- [Area 2 that needs tests]

## 📚 Documentation
- [ ] Code comments added where needed
- [ ] README updated (if applicable)
- [ ] API docs updated (if applicable)
- [ ] Breaking changes documented

## 🔒 Security Checklist
- [ ] No sensitive data in code
- [ ] Input validation present
- [ ] Authentication/authorization checks
- [ ] Dependency vulnerabilities checked
- [ ] SQL injection prevention
- [ ] XSS prevention

## 🎯 Action Items

**Before Merge**:
1. [Critical fix 1]
2. [Critical fix 2]

**Future Improvements** (can be separate PRs):
1. [Enhancement 1]
2. [Enhancement 2]

## 📝 Reviewer Notes
[Any additional context, questions for the author, or architectural concerns]

---
**Review completed by Claude Code** 🤖
```

### 4. Post Review Comment

If the review has critical issues, ask user if they want to post the review as a PR comment:

```bash
# Post review as comment
gh pr review $ARGUMENTS --comment --body "[Generated review markdown]"
```

Or for approval:

```bash
# Approve PR
gh pr review $ARGUMENTS --approve --body "[Generated review markdown]"
```

Or request changes:

```bash
# Request changes
gh pr review $ARGUMENTS --request-changes --body "[Generated review markdown]"
```

### 5. Generate Code Suggestions

For each improvement suggestion, create reviewable suggestions using GitHub's suggestion format:

````markdown
```suggestion
[improved code here]
```
````

## Review Categories

### Security Analysis
- Authentication/Authorization
- Input validation
- SQL injection risks
- XSS vulnerabilities
- Secrets management
- Dependency security

### Code Quality
- Complexity (cyclomatic)
- Code duplication
- Naming conventions
- Error handling
- Resource management

### Performance
- Algorithm efficiency
- Database queries
- Memory usage
- Caching opportunities

### Testing
- Test coverage
- Edge cases
- Error scenarios
- Integration tests

### Documentation
- Code comments
- README updates
- API documentation
- Breaking changes

## Output Format

Present the review in a clear, actionable format:
1. Start with overall assessment
2. Highlight critical issues first
3. Group related issues together
4. Provide specific line numbers
5. Include code examples
6. Suggest concrete improvements

## Error Handling

- PR not found → Verify PR number
- No access → Check gh auth status
- Large diff → Focus on critical issues first

## Example Usage

```
/review-pr 123
/review-pr 456
```

---

**Remember**: Be thorough but constructive. Focus on helping improve the code, not just finding faults. Prioritize security and correctness, then quality and maintainability.
