---
name: Specification (SDD)
about: Create a formal specification for non-trivial changes
title: '[SPEC] Brief Description'
labels: spec
assignees: ''

---

### Spec Type

*Select the type of specification:*

- [ ] **composition** - New Crossplane composition (KCL module, XRD)
- [ ] **infrastructure** - Major OpenTofu/Terramate changes (VPC, EKS, IAM)
- [ ] **security** - Network policies, RBAC, secrets, PKI
- [ ] **platform** - Multi-component features, observability, GitOps

### Summary

*1-2 sentences describing what this specification covers and why it's needed.*

### Problem Statement

*What problem does this change solve? Who experiences this problem?*

### User Stories

*Who benefits and how?*

- As a **[role]**, I want to [action], so that [benefit]

### Scope

**In Scope:**
- Item 1
- Item 2

**Out of Scope:**
- Item 1

### Success Criteria

*How will we know this is successful?*

- [ ] Criterion 1
- [ ] Criterion 2

### Spec File

*Will be linked here after creation via `/specify` command.*

---

**Note:** This issue serves as the anchor for discussion. The detailed specification with implementation design, review checklists, and technical details will be created in `docs/specs/active/`.

Use `/specify [type] [description]` to generate the full spec template.
