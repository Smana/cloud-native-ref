---
name: spec
description: Create a specification for non-trivial platform changes. Creates a GitHub issue anchored to a spec directory with the SDD template. Type is auto-inferred from the description; pass an explicit type to override.
when_to_use: |
  When the user says "start a spec", "new spec", "design a composition",
  "new KCL module", "let's spec this out", "proposal for X",
  or asks for planning a new Crossplane composition, major infrastructure
  change, security policy change, or multi-component platform feature.
disable-model-invocation: true
argument-hint: '"<description>"  (or:  <type> "<description>" to override inferred type)'
allowed-tools: Bash(./scripts/sdd/create-spec.sh:*), Bash(gh:*), Read
---

# Spec Skill

Create a lightweight specification for changes that benefit from upfront design review.

## Usage

```
/spec "Add Valkey caching"                                    # type inferred → composition
/spec "Restrict egress from observability namespace"          # type inferred → security
/spec "Add GPU node pool"                                     # type inferred → infrastructure
/spec security "Add OPA Gatekeeper for namespace isolation"   # explicit override
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

### 1. Run the creator script

Pass the description as a single argument — the script infers the type. Only pass an explicit type if the user provided one, or if the inferred type is clearly wrong for the request:

```bash
./scripts/sdd/create-spec.sh "<description>"            # inferred (default path)
./scripts/sdd/create-spec.sh <type> "<description>"     # explicit override
```

Inference rules (applied by the script — keep them in mind for borderline cases):

| Type | Triggers |
|------|----------|
| `security` | network policy, RBAC, PKI, OpenBao, cert-manager, TLS, certificate, Cilium policy |
| `composition` | KCL, composition, Crossplane, XRD, EPI |
| `infrastructure` | terraform, opentofu, VPC, EKS, Tailscale, subnet, `.tf`, node group, node pool, Karpenter |
| `platform` | anything else (cross-cutting / multi-component) |

The script writes a `key=value` report to stdout. Parse `spec_dir`, `issue_num`, `type`, and `type_source` for the confirmation message.

### 2. Confirm to the user

Report the created artifacts and next steps. When `type_source=inferred`, surface the inferred type so the user can correct it if wrong:

```
Spec created:
  Issue: <issue_url>  (label: spec:draft)
  Spec:  <spec_dir>/spec.md
  Type:  <type>  (inferred — edit **Type**: in spec.md if wrong)

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
- `/validate` — single quality gate (structural + cross-artifact + constitution)
- `/create-pr` — auto-detects spec directory and references issue
- GitHub Action `spec-archive.yaml` — archives spec on merge

## Files

- **Script**: [`scripts/sdd/create-spec.sh`](../../../scripts/sdd/create-spec.sh)
- **Template**: [`docs/specs/templates/spec.md`](../../../docs/specs/templates/spec.md)
- **Constitution**: [`docs/specs/constitution.md`](../../../docs/specs/constitution.md)
