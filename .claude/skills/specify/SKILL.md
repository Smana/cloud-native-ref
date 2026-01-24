---
name: specify
description: Generate a specification template for non-trivial changes using Spec-Driven Development. Creates GitHub issue + spec file following the 4-stage workflow (Specify → Clarify → Tasks → Implement).
allowed-tools: Read, Write, Bash(git:*), Bash(gh:*), Glob, Grep
---

# Specify Skill

Generate specification templates for changes that require formal design documentation before implementation.
Follows GitHub Spec Kit 4-stage workflow: **Specify → Clarify → Tasks → Implement**.

## Usage

```
/specify <type> [description]
```

**Types**: `composition` | `infrastructure` | `security` | `platform`

## When to Use

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

**If type argument provided**, use it directly.

**If type NOT provided**, use AskUserQuestion to prompt:

```
Question: "What type of specification do you want to create?"
Header: "Spec type"
Options:
  - composition: "New Crossplane KCL composition, XRD, or managed resource pattern"
  - infrastructure: "OpenTofu/Terramate changes (VPC, EKS, IAM, network)"
  - security: "Network policies, RBAC, secrets management, PKI changes"
  - platform: "Multi-component features spanning multiple subsystems"
```

**Context hints** (use to suggest a default, but always confirm with user):

| Type | Trigger Patterns |
|------|-----------------|
| `composition` | KCL files, `*-composition.yaml`, `*-definition.yaml` |
| `infrastructure` | `opentofu/**/*.tf`, `terramate.tm.hcl`, EKS/VPC changes |
| `security` | `*networkpolicy*`, `*rbac*`, `openbao/**`, secrets |
| `platform` | Multi-directory changes, new HelmReleases, observability |

### Step 2: Get Description

**If description provided**, use it directly.

**If description NOT provided**, ask the user:
- "Briefly describe what you want to specify (e.g., 'Add Valkey caching composition for Redis workloads')"

### Step 3: Generate Semantic Slug

From description, create a slug:
- Filter out stop words (I, want, to, the, for, a, an, etc.)
- Take 3-4 most meaningful words
- Join with hyphens, lowercase
- Example: "Create a Valkey caching composition" → "valkey-caching-composition"

### Step 4: Create GitHub Issue (Anchor)

Create a GitHub issue as the immutable anchor for discussion and tracking:

```bash
# Create issue and capture the issue number directly from the output
ISSUE_URL=$(gh issue create \
  --title "[SPEC] ${TITLE}" \
  --label "spec,${TYPE}" \
  --body "## Summary
${DESCRIPTION}

## Spec Type
${TYPE}

## Spec File
Will be created at: \`docs/specs/active/XXXX-#ISSUE-${SLUG}.md\`

---
_This issue tracks a formal specification. See the linked spec file for full details._")

# Extract issue number from the returned URL
ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oP 'issues/\K\d+$')
```

**Why GitHub Issue first?**
- Provides discoverability (searchable, project boards)
- Enables discussion (comments, reactions, mentions)
- Creates linkable anchor for PRs (`Implements #123`)
- Separates "what/why" (issue) from "how" (spec file)

### Step 5: Generate Spec Number

```bash
# Find next spec number by extracting the highest existing number
MAX_NUM=$(ls -1 docs/specs/active/*.md docs/specs/completed/*.md 2>/dev/null | \
  sed 's|.*/||' | \
  grep -oP '^\d{4}(?=-)' | \
  sort -rn | \
  head -1)
SPEC_NUM=$(printf "%04d" $((10#${MAX_NUM:-0} + 1)))
```

### Step 6: Create Spec File

```bash
# Include issue number in filename for traceability
SPEC_FILE="docs/specs/active/${SPEC_NUM}-#${ISSUE_NUM}-${SLUG}.md"
```

Copy the appropriate template:
- `composition` → `docs/specs/templates/spec-crossplane-composition.md`
- `infrastructure` → `docs/specs/templates/spec-infrastructure.md`
- `security` → `docs/specs/templates/spec-security.md`
- `platform` → `docs/specs/templates/spec-platform-capability.md`

### Step 7: Pre-fill Context

Replace placeholders in the template:
- `SPEC-XXXX` → `SPEC-${SPEC_NUM}`
- `YYYY-MM-DD` → current date
- `[Composition Name]` / `[Title]` → derived from description
- `GitHub Issue: #XXX` → `GitHub Issue: #${ISSUE_NUM}`

### Step 8: Update GitHub Issue with Spec Link

```bash
gh issue comment ${ISSUE_NUM} --body "Spec file created: [\`${SPEC_FILE}\`](${SPEC_FILE})"
```

### Step 9: Read Related Context

To help fill in the template, scan relevant files (only if they exist):

```bash
# Always read these core files
[ -f "CLAUDE.md" ] && echo "Read: CLAUDE.md"
[ -f "docs/specs/constitution.md" ] && echo "Read: constitution.md (platform principles)"

# Type-specific context (only if files exist)
if [ "$TYPE" = "composition" ]; then
  [ -f "docs/crossplane.md" ] && echo "Read: docs/crossplane.md"
fi

# Optional architectural context
[ -f "docs/technology-choices.md" ] && echo "Read: docs/technology-choices.md"

# Always scan similar completed specs for patterns
ls docs/specs/completed/*.md 2>/dev/null | head -3
```

**Required context files**:
- `CLAUDE.md` - Project patterns and validation requirements
- `docs/specs/constitution.md` - Platform-wide non-negotiable principles

**Optional context files** (read if they exist):
- `docs/crossplane.md` - Composition patterns (for composition type)
- `docs/technology-choices.md` - Architectural context
- `docs/specs/completed/*.md` - Similar completed specs for reference

### Step 10: Output

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
2. Run /clarify to resolve clarifications interactively
3. Run /tasks to generate task breakdown
4. Implement the changes
5. Reference issue in PR: `Implements #XXX`
6. After merge: `mv docs/specs/active/XXXX-*.md docs/specs/completed/`
7. Close the GitHub issue
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

## Integration with Other Skills

- `/specify` → Creates GitHub issue + spec file (this skill)
- `/clarify` → Resolves `[NEEDS CLARIFICATION]` markers interactively
- `/tasks` → Generates task breakdown from spec's Rollout Plan
- `/create-pr` → Auto-detects spec and references issue (`Implements #XXX`)

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

## Two-Document Model

| Document | Purpose | Location |
|----------|---------|----------|
| **GitHub Issue** | Immutable anchor, discussion, "what/why" | GitHub Issues |
| **Spec File** | Detailed design, checklists, "how" | `docs/specs/active/` |

The issue provides discoverability and discussion; the spec file contains implementation details.
