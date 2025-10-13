---
allowed-tools: Bash(gh:*), Bash(git:*), Edit, Write, Read
argument-hint: <pr-number>
description: Comprehensive PR analysis with security review and automatic code improvements
---

# Claude Code Command: Improve Pull Request

This command performs comprehensive PR analysis combining security review, best practices assessment, and actionable code improvements with auto-apply capability.

## Instructions

**IMPORTANT**: Use context7 to understand the codebase architecture, security requirements, coding standards, and best practices before analyzing the PR.

### 1. Fetch PR Information and Checkout Branch

```bash
# Get PR details
PR_INFO=$(gh pr view $ARGUMENTS --json headRefName,baseRefName,files,title,additions,deletions)
HEAD_BRANCH=$(echo $PR_INFO | jq -r '.headRefName')

# Checkout the PR branch
git fetch origin
git checkout $HEAD_BRANCH
git pull origin $HEAD_BRANCH

# Get the diff
gh pr diff $ARGUMENTS

# Get PR checks status
gh pr checks $ARGUMENTS
```

### 2. Comprehensive Analysis

Analyze the code across multiple dimensions:

**🔒 Security Analysis**:
- SQL injection vulnerabilities
- XSS (Cross-Site Scripting) risks
- Authentication/authorization issues
- Secrets in code (API keys, passwords)
- Insecure dependencies
- CSRF protection
- Input validation
- Cryptography weaknesses

**🎨 Code Quality**:
- Extract duplicate code into functions
- Simplify complex conditionals
- Improve variable/function naming
- Add error handling
- Reduce nesting depth
- Apply SOLID principles
- Code complexity (cyclomatic complexity)

**⚡ Performance**:
- Optimize algorithms
- Reduce database queries (N+1 issues)
- Add caching where appropriate
- Lazy load resources
- Parallel processing opportunities
- Memory leaks
- Resource cleanup

**📖 Readability**:
- Add clarifying comments
- Break down large functions
- Improve code organization
- Use descriptive names
- Add type hints/annotations

**✨ Best Practices**:
- Follow language idioms
- Use modern syntax
- Apply design patterns
- Improve error messages
- Add logging where helpful
- Follow project conventions

**🧪 Testing Coverage**:
- Missing unit tests
- Untested edge cases
- Error handling tests
- Integration test gaps

### 3. Generate Comprehensive Report

Create a structured report with all findings:

```markdown
# 🚀 PR Analysis & Improvements: #$ARGUMENTS - [PR Title]

## 📊 Overview
- **Files Changed**: [count]
- **Lines Added**: [+count]
- **Lines Deleted**: [-count]
- **Overall Quality**: ⭐⭐⭐⭐⭐ (1-5 stars)

---

## 🔒 Security Analysis

### ✅ Security Strengths
- [Security best practice observed 1]
- [Security best practice observed 2]

### 🔴 Security Issues (MUST FIX)

| Severity | File | Line | Issue | Risk | Fix |
|----------|------|------|-------|------|-----|
| 🔴 Critical | path/file | L42 | SQL Injection | Data breach | Use parameterized queries |
| 🔴 High | path/file | L15 | Hardcoded secret | Credential exposure | Move to environment variables |

### 🟡 Security Warnings

| Severity | File | Line | Issue | Recommendation |
|----------|------|------|-------|----------------|
| 🟡 Medium | path/file | L89 | Missing input validation | Add validation for user input |

---

## 🎨 Code Quality Improvements

### Summary
Found **[count]** improvement opportunities across **[count]** files

### Improvements by Category
- 🔒 Security: [count] issues
- 🎨 Code Quality: [count] suggestions
- ⚡ Performance: [count] optimizations
- 📖 Readability: [count] enhancements
- ✨ Best Practices: [count] recommendations

---

## File-by-File Improvements

### 📄 path/to/file1.ext

#### 1. Fix SQL Injection Vulnerability (Security - CRITICAL)
**Priority**: 🔴 Critical
**Lines**: 45-48
**Impact**: Prevents SQL injection attacks

**Current Code** (VULNERABLE):
```language
query = "SELECT * FROM users WHERE id = " + user_input
db.execute(query)
```

**Improved Code** (SECURE):
```language
query = "SELECT * FROM users WHERE id = ?"
db.execute(query, [user_input])
```

**Benefits**:
- Prevents SQL injection attacks
- Protects against data breaches
- Follows security best practices

---

#### 2. Extract Duplicate Logic (Code Quality)
**Priority**: 🟡 High
**Lines**: 78-92, 103-117
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

#### 3. Optimize Database Query (Performance)
**Priority**: 🟡 Medium
**Lines**: 125-130
**Impact**: Reduces N+1 queries from 100+ to 1

**Current Code**:
```language
for user in users:
    posts = db.query("SELECT * FROM posts WHERE user_id = ?", user.id)
```

**Improved Code**:
```language
user_ids = [u.id for u in users]
posts = db.query("SELECT * FROM posts WHERE user_id IN (?)", user_ids)
```

**Benefits**:
- Reduces database calls from N to 1
- Improves response time by ~90%
- Lower database load

---

### 📄 path/to/file2.ext

[Continue with similar structure for each file]

---

## 🎯 Implementation Priority

### 🔴 Critical (MUST fix before merge)
1. **file1.ext:45** - SQL Injection vulnerability - **Estimated: 5m**
2. **file2.ext:78** - Hardcoded API key - **Estimated: 2m**

### 🟡 High Priority (Should implement now)
1. **file1.ext:78** - Extract duplicate logic - **Estimated: 10m**
2. **file3.ext:125** - Optimize N+1 query - **Estimated: 5m**

### 🟢 Medium Priority (Consider for this PR)
1. **file4.ext:50** - Add error handling - **Estimated: 5m**
2. **file5.ext:100** - Improve naming - **Estimated: 3m**

### ⚪ Low Priority (Future enhancement)
1. **file6.ext:200** - Add type hints - **Estimated: 10m**

---

## 🧪 Testing Coverage

### Current Coverage
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Edge cases covered
- [ ] Error handling tested
- [ ] Security tests added

### Missing Coverage
**Critical Gaps**:
- [ ] **file1.ext:45-60** - SQL injection test needed
- [ ] **file2.ext:100-120** - Error handling not tested

**Recommended Tests**:
- Add test for SQL injection prevention
- Add test for invalid input handling
- Add test for authentication bypass attempts

---

## 📚 Documentation

### Documentation Status
- [ ] Code comments added where needed
- [ ] README updated (if applicable)
- [ ] API documentation updated
- [ ] Security considerations documented

### Missing Documentation
- Document security assumptions in file1.ext
- Add usage examples to README
- Document breaking changes

---

## 📊 Impact Summary

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Security Issues | [count] | 0 | ✅ All fixed |
| Lines of Code | [count] | [count] | -X% |
| Cyclomatic Complexity | [avg] | [avg] | -X% |
| Code Duplication | [count] | [count] | -X% |
| Function Length (avg) | [lines] | [lines] | -X% |
| Database Queries | N+1 | 1 | -99% |

---

## 🔧 Auto-Apply Available

I can automatically apply these improvements (except critical security fixes which need manual review).

**Options**:
- **A)** Apply all critical security fixes + high priority improvements
- **B)** Apply high priority improvements only (safer)
- **C)** Apply specific improvements (you choose which)
- **D)** Show detailed changes first (don't apply yet)
- **E)** Post as PR comment for team review

Which option would you prefer?
```

### 4. Wait for User Choice

Based on user selection:

**Option A/B/C - Auto-apply**:
```bash
# For each improvement:
# 1. Use Edit tool to apply the change
# 2. Verify syntax is correct
# 3. Track what was changed

# After all changes:
git add .
git commit -m "🚀 improve: apply AI-suggested improvements

Security fixes:
- Fix SQL injection in file1.ext:45
- Remove hardcoded secret in file2.ext:78

Code quality:
- Extract duplicate logic in file1.ext
- Optimize database queries in file3.ext
- Add error handling in file4.ext

Applied [count] improvements across [count] files.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

git push origin $HEAD_BRANCH
```

**Option D - Show changes**:
- Display full git diff of proposed changes
- Don't commit or push
- Allow user to review before applying

**Option E - Post as PR comment**:
```bash
gh pr comment $ARGUMENTS --body "[Generated improvement report]"
```

### 5. Verification

After applying changes:

```bash
# Run any available tests
if [ -f "package.json" ]; then npm test; fi
if [ -f "pytest.ini" ]; then pytest; fi
if [ -f "Makefile" ]; then make test; fi

# Check syntax
# Language-specific linting commands

# Verify no regressions
git diff --stat
```

## Safety Checks

Before applying ANY improvement:
1. ✅ Verify syntax is valid
2. ✅ Ensure tests still pass (if available)
3. ✅ Preserve original functionality
4. ✅ Check no breaking changes introduced
5. ✅ Validate code compiles/runs
6. ✅ **NEVER auto-apply critical security fixes** - flag for manual review

## Security Priority

**CRITICAL**: Security issues require special handling:
- SQL Injection → **FLAG, don't auto-fix** (needs validation)
- Hardcoded secrets → **FLAG, don't auto-fix** (needs secret rotation)
- XSS vulnerabilities → **FLAG, don't auto-fix** (needs testing)
- Auth issues → **FLAG, don't auto-fix** (needs security review)

For security fixes, provide the fix but **require manual review and application**.

## Output Guidelines

**Be Specific**:
- Include exact line numbers
- Show before/after code
- Explain security impact
- Provide CVE references if applicable

**Be Practical**:
- Focus on high-impact changes
- Consider implementation effort
- Prioritize security over style

**Be Safe**:
- Don't break existing functionality
- Maintain backward compatibility
- Preserve test coverage
- Flag security issues for review

---

**Remember**: Security first, quality second, style third. Critical security issues must be flagged but not auto-applied without review.
