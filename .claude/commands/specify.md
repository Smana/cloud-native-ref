---
allowed-tools: Read, Write, Bash(git:*), Bash(gh:*), Glob, Grep
argument-hint: <type> (composition|infrastructure|security|platform) [description]
description: Generate a specification template for non-trivial changes using Spec-Driven Development
---

# Specify Command

Generate specification templates for changes that require formal design documentation before implementation.
Follows GitHub Spec Kit 4-stage workflow: Specify → Plan → Tasks → Implement.

## When to Use This Command

Run `/specify` when making:
- **composition**: New Crossplane compositions (KCL modules, XRDs)
- **infrastructure**: Major OpenTofu/Terramate changes (VPC, EKS, IAM)
- **security**: Network policies, RBAC, secrets management, PKI
- **platform**: Multi-component features spanning multiple subsystems

## When NOT to Use

Skip specs for:
- Version bumps (Renovate PRs)
- Documentation-only changes
- Single-file bug fixes
- Minor HelmRelease value tweaks

## Workflow

### Step 1: Determine Spec Type

If type argument provided, use it. Otherwise, detect from context:

| Type | Trigger Patterns |
|------|-----------------|
| `composition` | KCL files, `*-composition.yaml`, `*-definition.yaml` |
| `infrastructure` | `opentofu/**/*.tf`, `terramate.tm.hcl`, EKS/VPC changes |
| `security` | `*networkpolicy*`, `*rbac*`, `openbao/**`, secrets |
| `platform` | Multi-directory changes, new HelmReleases, observability |

### Step 2: Generate Semantic Slug

From description, create a slug:
- Filter out stop words (I, want, to, the, for, a, an, etc.)
- Take 3-4 most meaningful words
- Join with hyphens, lowercase
- Example: "Create a Valkey caching composition" → "valkey-caching-composition"

### Step 3: Create GitHub Issue (Anchor)

Create a GitHub issue as the immutable anchor for discussion and tracking:

```bash
# Create issue using the spec template
gh issue create \
  --title "[SPEC] ${TITLE}" \
  --label "spec,${TYPE}" \
  --template "spec.md" \
  --body "## Summary
${DESCRIPTION}

## Spec Type
${TYPE}

## Spec File
Will be created at: \`docs/specs/active/XXXX-#ISSUE-${SLUG}.md\`

---
_This issue tracks a formal specification. See the linked spec file for full details._"

# Capture the issue number
ISSUE_NUM=$(gh issue list --limit 1 --json number --jq '.[0].number')
```

**Why GitHub Issue first?**
- Provides discoverability (searchable, project boards)
- Enables discussion (comments, reactions, mentions)
- Creates linkable anchor for PRs (`Implements #123`)
- Separates "what/why" (issue) from "how" (spec file)

### Step 4: Generate Spec Number

```bash
# Find next spec number
EXISTING=$(ls -1 docs/specs/active/*.md docs/specs/completed/*.md 2>/dev/null | wc -l)
SPEC_NUM=$(printf "%04d" $((EXISTING + 1)))
```

### Step 5: Create Spec File

```bash
# Include issue number in filename for traceability
SPEC_FILE="docs/specs/active/${SPEC_NUM}-#${ISSUE_NUM}-${SLUG}.md"
```

Copy the appropriate template:
- `composition` → `docs/specs/templates/spec-crossplane-composition.md`
- `infrastructure` → `docs/specs/templates/spec-infrastructure.md`
- `security` → `docs/specs/templates/spec-security.md`
- `platform` → `docs/specs/templates/spec-platform-capability.md`

### Step 6: Pre-fill Context

Replace placeholders in the template:
- `SPEC-XXXX` → `SPEC-${SPEC_NUM}`
- `YYYY-MM-DD` → current date
- `[Composition Name]` / `[Title]` → derived from description
- `GitHub Issue: #XXX` → `GitHub Issue: #${ISSUE_NUM}`

### Step 7: Update GitHub Issue with Spec Link

```bash
# Add comment linking to the spec file
gh issue comment ${ISSUE_NUM} --body "Spec file created: [\`${SPEC_FILE}\`](${SPEC_FILE})"
```

### Step 8: Read Related Context

To help fill in the template, scan relevant files:
- `CLAUDE.md` for project patterns and validation requirements
- `docs/crossplane.md` for composition patterns (if composition type)
- `docs/technology-choices.md` for architectural context
- Existing similar specs in `docs/specs/completed/`

### Step 9: Output

Display:
1. GitHub issue URL
2. Created spec file path
3. Template type used
4. Quick reference to the 4 personas who should review
5. Next steps

## Output Format

```
✅ Specification created!

🔗 GitHub Issue: https://github.com/Smana/cloud-native-ref/issues/XXX
📄 Spec File: docs/specs/active/XXXX-#XXX-slug.md
📋 Type: [composition|infrastructure|security|platform]

## Review Personas
Before implementation, self-review as:
- [ ] PM: Problem clear? User stories valid? Scope defined?
- [ ] Platform Engineer: Patterns consistent? Implementation feasible?
- [ ] Security & Compliance: Zero-trust? Least privilege? Secrets managed?
- [ ] SRE: Observable? Recoverable? Failure modes documented?

## Next Steps
1. Fill in the spec template (especially [NEEDS CLARIFICATION] sections)
2. Complete the review checklist
3. Implement the changes
4. Reference issue in PR: `Implements #XXX`
5. After merge: `mv docs/specs/active/XXXX-*.md docs/specs/completed/`
6. Close the GitHub issue
```

## Examples

```bash
# Explicit type
/specify composition Create a Valkey caching composition for Redis workloads

# Explicit type
/specify infrastructure Add Karpenter provisioner for GPU nodes

# Explicit type
/specify security Implement network policies for apps namespace

# Explicit type
/specify platform Add distributed tracing with Tempo
```

## Integration with Other Commands

- `/specify` → Creates GitHub issue + spec file
- `/create-pr` → Auto-detects spec and references issue (`Implements #XXX`)
- `/commit` → Standard commit (unchanged)

## Spec Lifecycle

```
┌─────────────────┐     ┌──────────────────────────────────┐     ┌─────────────────────┐
│  GitHub Issue   │────▶│  docs/specs/active/XXXX-#XX.md   │────▶│  docs/specs/completed/
│  #XXX (anchor)  │     │  (detailed spec)                 │     │  XXXX-#XX.md        │
└─────────────────┘     └──────────────────────────────────┘     └─────────────────────┘
       │                              │                                    │
       │                              ▼                                    │
       │                     [Implementation]                              │
       │                              │                                    │
       ▼                              ▼                                    ▼
   Discussion              PR: "Implements #XXX"                    Reference
   Comments                     Code Review                         History
   Reactions                       Merge
```

## Two-Document Model (inspired by dot-ai)

| Document | Purpose | Location |
|----------|---------|----------|
| **GitHub Issue** | Immutable anchor, discussion, "what/why" | GitHub Issues |
| **Spec File** | Detailed design, checklists, "how" | `docs/specs/active/` |

The issue provides discoverability and discussion; the spec file contains implementation details.
