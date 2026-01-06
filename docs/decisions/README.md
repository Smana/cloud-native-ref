# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records (ADRs) documenting significant technical decisions for the cloud-native-ref platform.

## What is an ADR?

An ADR is a document that captures an important architectural decision along with its context and consequences. ADRs help:

- **Record** the "why" behind decisions (not just the "what")
- **Communicate** decisions to current and future team members
- **Prevent** revisiting the same discussions repeatedly
- **Provide** historical context when evaluating changes

## When to Create an ADR

Create an ADR when making decisions that:

- Affect multiple components or systems
- Are difficult to reverse
- Have significant trade-offs
- Will be questioned by future team members
- Involve choosing between multiple valid approaches

**Examples**:
- Choosing KCL over Go templates for compositions (ADR-0001)
- Selecting Cilium as the CNI
- Adopting Gateway API over Ingress
- Using OpenBao instead of HashiCorp Vault

## ADR Lifecycle

```
Proposed → Accepted → [Deprecated | Superseded by ADR-XXXX]
```

- **Proposed**: Decision under discussion
- **Accepted**: Decision agreed upon and implemented
- **Deprecated**: Decision no longer applies
- **Superseded**: Replaced by a newer decision

## Directory Structure

```
docs/decisions/
├── README.md           # This file
├── template.md         # ADR template
├── 0001-use-kcl-for-crossplane-compositions.md
└── NNNN-decision-title.md
```

## Creating a New ADR

1. Copy the template:
   ```bash
   cp docs/decisions/template.md docs/decisions/NNNN-short-title.md
   ```

2. Fill in the sections:
   - **Context**: What situation led to this decision?
   - **Decision Drivers**: What factors influenced the choice?
   - **Considered Options**: What alternatives were evaluated?
   - **Decision Outcome**: What was chosen and why?
   - **Consequences**: What are the positive and negative effects?

3. Submit for review via PR

## ADR Template Structure

```markdown
# ADR-XXXX: [Decision Title]

**Status**: Proposed | Accepted | Deprecated | Superseded
**Date**: YYYY-MM-DD
**Deciders**: [Names or roles]
**Related Spec**: [SPEC-XXXX if applicable]

## Context
[What is the issue motivating this decision?]

## Decision Drivers
[What factors influenced this decision?]

## Considered Options
[What alternatives were evaluated?]

## Decision Outcome
[What was chosen and why?]

## Consequences
[What are the positive and negative effects?]

## References
[Links to related resources]
```

## Numbering Convention

ADRs are numbered sequentially:
- `0001-use-kcl-for-crossplane-compositions.md`
- `0002-adopt-gateway-api.md`
- etc.

## Relationship to Specs

ADRs and Specs serve different purposes:

| Aspect | ADR | Spec |
|--------|-----|------|
| **Focus** | Technology/architectural choices | Feature implementation details |
| **Scope** | Cross-cutting decisions | Single feature/change |
| **Lifespan** | Long-term reference | Active during implementation |
| **Question** | "Why did we choose X?" | "How do we build Y?" |

A Spec may reference ADRs for context, and implementing a Spec may result in new ADRs.

## Existing ADRs

| ID | Title | Status | Date |
|----|-------|--------|------|
| [0001](0001-use-kcl-for-crossplane-compositions.md) | Use KCL for Crossplane Compositions | Accepted | 2024-01-15 |
| [0002](0002-eks-pod-identity-over-irsa.md) | Use EKS Pod Identity over IRSA | Accepted | 2024-01-15 |

## Further Reading

- [Documenting Architecture Decisions](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) - Michael Nygard's original article
- [MADR Template](https://adr.github.io/madr/) - Markdown ADR template
- [ADR GitHub Organization](https://adr.github.io/) - Tools and resources
