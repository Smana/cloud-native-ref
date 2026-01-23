---
name: clarify
description: Resolve [NEEDS CLARIFICATION] markers in a specification file through structured questioning. Part of the SDD workflow after /specify.
allowed-tools: Read, Edit, Glob, Grep, AskUserQuestion
---

# Clarify Skill

Interactively resolve `[NEEDS CLARIFICATION: ...]` markers in a specification file. This ensures all ambiguities are addressed before implementation begins.

## Usage

```
/clarify [spec-file]
```

If no file specified, uses the most recently modified spec in `docs/specs/active/`.

## When to Use

Run `/clarify` after creating a spec with `/specify` to:
- Identify unresolved questions in the spec
- Get structured answers from the user
- Update the spec with clarifications
- Validate that all markers are resolved before implementation

## Workflow

### Step 1: Find the Active Spec

If no argument provided, find the most recently modified spec in `docs/specs/active/`:

```bash
SPEC_FILE=$(ls -t docs/specs/active/*.md 2>/dev/null | head -1)
```

If argument provided, use it directly:
```bash
SPEC_FILE="docs/specs/active/$1"
```

### Step 2: Extract Clarification Markers

Scan the spec file for `[NEEDS CLARIFICATION: ...]` patterns:

```bash
grep -oP '\[NEEDS CLARIFICATION: [^\]]+\]' "$SPEC_FILE"
```

### Step 3: Present Each Marker as a Question

For each marker found:
1. Extract the question text
2. Show the surrounding context (2-3 lines before/after)
3. Use `AskUserQuestion` to get the answer
4. Record the response

### Step 4: Update the Spec

Replace each marker with the clarified version:

```markdown
# Before
- [NEEDS CLARIFICATION: Should cache support cross-namespace access?]

# After
- [CLARIFIED: No, cache is namespace-scoped for security isolation. Cross-namespace access would require explicit network policies.]
```

### Step 5: Verify No Markers Remain

After processing all markers:
```bash
REMAINING=$(grep -c '\[NEEDS CLARIFICATION:' "$SPEC_FILE" || echo "0")
if [ "$REMAINING" -gt 0 ]; then
    echo "WARNING: $REMAINING unresolved markers remain"
fi
```

### Step 6: Output Summary

```
✅ Clarifications complete!

📄 Spec File: docs/specs/active/0001-#123-valkey-caching.md
📋 Markers Resolved: 3/3
⚠️ Remaining: 0

## Clarifications Made:
1. Cache scope → Namespace-scoped for security
2. Eviction policy → LRU with 1GB max memory
3. TLS requirement → Required for production, optional for dev

## Next Steps:
1. Review the updated spec
2. Complete the review checklist
3. Run /tasks to generate task breakdown
4. Begin implementation
```

## Example Session

```
/clarify 0001-#123-valkey-caching.md

📋 Found 3 clarification markers in spec:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1/3] NEEDS CLARIFICATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Context:
> ### Non-Goals
> - [NEEDS CLARIFICATION: Should cache support cross-namespace access?]

Question: Should the cache support cross-namespace access, or should it be scoped to a single namespace?

[User provides answer via AskUserQuestion]

✅ Updated to: [CLARIFIED: No, cache is namespace-scoped...]

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[2/3] NEEDS CLARIFICATION
...
```

## Marker Format

**Input markers** (in spec):
```markdown
[NEEDS CLARIFICATION: Question about the design or requirement?]
```

**Output markers** (after clarification):
```markdown
[CLARIFIED: Answer provided by the user or determined through discussion.]
```

## Integration with Other Skills

- `/specify` → Creates spec with `[NEEDS CLARIFICATION]` markers
- `/clarify` → Resolves markers interactively (this skill)
- `/tasks` → Should check that no unresolved markers exist
- `/create-pr` → Warns if spec has unresolved markers

## Validation

Before implementation, ensure:
- [ ] No `[NEEDS CLARIFICATION:]` markers remain
- [ ] All `[CLARIFIED:]` markers have meaningful answers
- [ ] Review checklist is complete

## Tips

1. **Add markers liberally**: When creating specs, add `[NEEDS CLARIFICATION]` markers for anything uncertain
2. **Run early**: Clarify specs before starting implementation
3. **Be specific**: Clarifications should be actionable, not vague
4. **Update related sections**: When clarifying, also update related parts of the spec

## Error Handling

- If no spec file found: Prompt user to specify file or run `/specify` first
- If no markers found: Report "No clarifications needed" and exit
- If user skips a question: Keep the original marker and continue
