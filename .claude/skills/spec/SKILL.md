---
name: spec
description: Create a specification for non-trivial platform changes. Creates a GitHub issue anchored to a spec directory with the SDD template.
when_to_use: |
  When the user says "start a spec", "new spec", "design a composition",
  "new KCL module", "let's spec this out", "proposal for X",
  or asks for planning a new Crossplane composition, major infrastructure
  change, security policy change, or multi-component platform feature.
disable-model-invocation: true
argument-hint: '[type] "description" — types: composition | infrastructure | security | platform'
allowed-tools: Bash(./scripts/sdd/create-spec.sh:*), Bash(gh:*), Read
---

# Spec Skill

Create a lightweight specification for changes that benefit from upfront design review.

## Usage

```
/spec composition "Add Valkey caching"
/spec infrastructure "Add GPU node pool"
/spec security "Restrict egress from observability namespace"
/spec "Description without type"   # infer type from description
```

## When to Use

Run `/spec` for changes that warrant review *before* implementation:

- New Crossplane composition (KCL module or XRD)
- Major infrastructure (new OpenTofu stack, VPC/EKS upgrade)
- Security changes (network policies, RBAC, PKI, secrets)
- Multi-component platform features

## When NOT to Use

- Version bumps (Renovate PRs)
- Documentation-only changes
- Single-file bug fixes
- HelmRelease value tweaks

## Workflow

### 1. Determine type

If the user omitted `<type>`, infer from the description (KCL/composition → `composition`; `.tf`/VPC/EKS → `infrastructure`; network policy/RBAC/PKI → `security`; anything cross-cutting → `platform`). Ask if genuinely ambiguous.

### 2. Run the creator script

The script handles numbering, slug generation, GitHub issue creation, and template instantiation:

```bash
./scripts/sdd/create-spec.sh <type> "<description>"
```

It writes a `key=value` report to stdout. Parse `spec_dir` and `issue_num` for the confirmation message.

### 3. Confirm to the user

Report the created artifacts and next steps:

```
Spec created:
  Issue: <issue_url>  (label: spec:draft)
  Spec:  <spec_dir>/spec.md

Next:
  1. Fill in the spec (mark unknowns [NEEDS CLARIFICATION: ...])
  2. /clarify to resolve unknowns
  3. /validate to check completeness
  4. Review 4-persona checklist
  5. When starting work:
     gh issue edit <issue_num> --remove-label spec:draft --add-label spec:implementing
  6. Reference in PR: "Implements #<issue_num>"
  7. Auto-archived on merge
```

## Integration

- `/spec-research <topic>` — optional deep research subagent (writes `research.md` alongside spec)
- `/clarify` — resolve `[NEEDS CLARIFICATION: ...]` markers
- `/validate` — check spec completeness
- `/analyze` (future) — cross-artifact consistency
- `/create-pr` — auto-detects spec directory and references issue
- GitHub Action `spec-archive.yaml` — archives spec on merge

## Files

- **Script**: [`scripts/sdd/create-spec.sh`](../../../scripts/sdd/create-spec.sh)
- **Template**: [`docs/specs/templates/spec.md`](../../../docs/specs/templates/spec.md)
- **Constitution**: [`docs/specs/constitution.md`](../../../docs/specs/constitution.md)
