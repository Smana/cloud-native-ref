---
title: Use OpenTofu rather than Terraform
linkTitle: 0014 · OpenTofu over Terraform
weight: 140
description: Infrastructure as code runs on OpenTofu after HashiCorp's BUSL relicensing — a drop-in for this repository's provider set, though the OpenBao stack still depends on the hashicorp/vault provider.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow
**Related**: [ADR-0011](0011-openbao-over-vault.md) — the same BUSL
relicensing trigger, applied to Vault

---

## Context

This platform's infrastructure below Kubernetes — network, OpenBao, and both
EKS bootstrap stages — is written in HCL and applied through
`terramate script run deploy` (see [ADR-0012](0012-crossplane-and-opentofu.md)
for what that split from Crossplane covers). The tool that actually executes
that HCL is OpenTofu, not HashiCorp Terraform: `mise.toml` pins
`opentofu = "1.12.6"` and carries no `terraform` entry at all.

The trigger is the one [ADR-0011](0011-openbao-over-vault.md) already
records for Vault: in 2023 HashiCorp relicensed its tools under the Business
Source License (BUSL). [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}})
already states the Terraform-specific consequence plainly: "OpenTofu is the
open-source fork of Terraform, created after HashiCorp moved Terraform off an
OSI-approved license. It is now a Linux Foundation project with community
governance, and it stayed compatible with existing Terraform configuration
and providers." This record exists to state that choice formally and name
its actual cost, rather than repeat ADR-0011's reasoning for a different
tool.

Every stack's `versions.tf` still opens with a plain `terraform { ... }`
block and an unmodified `required_providers` map — nothing about the HCL
itself changed to move the toolchain; only the binary and its pin did.

---

## Decision Drivers

- **Licence continuity**, the same driver as ADR-0011: a reference platform
  anyone can clone and run should not depend on a component whose
  commercial terms one vendor can change underneath it.
- **No configuration rewrite.** Every stack already declares a plain
  `terraform { ... }` block; whatever replaced Terraform had to keep
  executing that block unmodified, not force new HCL.
- **Provider availability.** The specific providers this repository's
  stacks already pin had to resolve from wherever the replacement tool
  pulls providers, or the migration cost stops being close to zero.
- **Orchestration continuity.** Terramate (`opentofu/workflows.tm.hcl`,
  `opentofu/config.tm.hcl`) sequences and invokes the provisioner; the
  replacement should not require rewriting that orchestration layer.

---

## Considered Options

### Option 1: OpenTofu

Adopt OpenTofu as the pinned provisioner binary, with the existing stacks,
providers and Terramate orchestration otherwise unchanged.

**Pros**:
- Every stack's `terraform { ... }` block and `required_providers` map runs
  unmodified — `mise.toml`'s `opentofu = "1.12.6"` is the only place the
  tool name changed.
- The full provider set this repository's stacks declare resolves without
  substitution: `gavinbunney/kubectl`, `hashicorp/aws`, `hashicorp/cloudinit`,
  `hashicorp/helm`, `hashicorp/http`, `hashicorp/random`, `hashicorp/time`,
  `hashicorp/tls`, `hashicorp/vault`, `integrations/github`,
  `tailscale/tailscale`.
- Terramate's scripts (`opentofu/workflows.tm.hcl`) call
  `global.provisioner`, set to `"tofu"` in `opentofu/config.tm.hcl` —
  orchestration needed a one-line global change, not a rewrite.
  **Update (2026-08-30):** `global.provisioner` was repointed on 2026-08-29 to
  `scripts/tm-provisioner.sh`, a wrapper that gates on `TM_CLOUD` before
  `exec`-ing `tofu` — see the Neutral section below for what stayed the same
  through that change.
- Linux Foundation governance, the same neutral-governance argument
  [ADR-0011](0011-openbao-over-vault.md) makes for OpenBao.

**Cons**:
- Younger project than Terraform, with a correspondingly smaller (if
  actively growing) contributor base and body of third-party writeups.
- A separate registry from Terraform's — provider publication there
  depends on each provider's own maintainer, not on OpenTofu's
  compatibility layer (see Consequences).

### Option 2: Stay on Terraform under the BUSL

Keep HashiCorp Terraform, accepting the relicensing rather than migrating.

**Pros**:
- No migration at all — the existing HCL, state and CI already target
  Terraform.
- Larger ecosystem, official HashiCorp support available if ever needed.

**Cons**:
- Runs the exact licence risk this decision exists to avoid, on the tool
  that provisions every stage below Kubernetes — the same argument
  [ADR-0011](0011-openbao-over-vault.md) makes for Vault, one layer further
  down the stack.
- Undercuts the point of a reference platform: someone cloning this repo to
  learn from or run it themselves would inherit a BUSL dependency at the
  very bottom of it.

### Option 3: Pulumi or CDK for Terraform

Rewrite the stacks in a general-purpose language instead of HCL, sidestepping
the Terraform/OpenTofu choice entirely.

**Pros**:
- Leaves the HCL licence question behind rather than choosing between two
  licence terms for the same configuration language.
- Real programming-language constructs (loops, functions, types) in place
  of HCL's more limited expression language.

**Cons**:
- Every existing stack — `network`, `openbao/cluster`, `openbao/management`,
  `eks/init`, `eks/configure` — would need a full rewrite, not a binary
  swap.
- A new state model and CI toolchain on top of that rewrite, with nothing
  equivalent to Terramate's stack ordering, drift detection or opt-in
  gating already in place.
- Does not actually remove the dependency this decision is about: both
  Pulumi's Terraform bridge and CDK for Terraform still resolve and shell
  out to the same provider plugins, so the question of which licence those
  provider binaries ship under does not disappear, it just moves.

---

## Decision Outcome

**Chosen option**: "Option 1 — OpenTofu"

**Rationale**: The trigger and the reasoning shape are the same as
[ADR-0011](0011-openbao-over-vault.md): the licence risk is real, and
removing it costs close to nothing because OpenTofu stayed compatible with
the exact configuration and providers already written. Option 2 keeps the
licence exposure this decision exists to remove, on the tool that sits below
every other stage in the platform. Option 3 removes that exposure too, but
only by paying for a full rewrite Option 1 does not require, and even then it
does not remove the underlying dependency on Terraform-shaped provider
binaries — it moves the question rather than answering it. Option 1 is the
only path that resolves the licence question for the cost of a tool-name
change.

---

## Consequences

### Positive

- Every `versions.tf` and its `required_providers` block runs unmodified;
  the only artifact that named the tool differently was `mise.toml`.
- The confirmed provider set — `gavinbunney/kubectl`, `hashicorp/aws`,
  `hashicorp/cloudinit`, `hashicorp/helm`, `hashicorp/http`,
  `hashicorp/random`, `hashicorp/time`, `hashicorp/tls`, `hashicorp/vault`,
  `integrations/github`, `tailscale/tailscale` — resolves without
  substitution.
- Terramate orchestration required no rewrite: `opentofu/workflows.tm.hcl`'s
  `init`, `preview`, `deploy`, `drift detect`, `drift reconcile` and
  `destroy` scripts all invoke `global.provisioner`, which names the
  actual binary — `opentofu/config.tm.hcl`'s single `provisioner` line, now
  the `scripts/tm-provisioner.sh` wrapper that execs `tofu`.
- The same neutral-governance benefit [ADR-0011](0011-openbao-over-vault.md)
  records for OpenBao: no single vendor controls the commercial terms this
  platform's IaC tool runs under.

### Negative

- **A HashiCorp-published provider still configures the OpenBao stack.**
  `opentofu/aws/openbao/management/versions.tf` pins
  `vault = { source = "hashicorp/vault", version = "~> 5.0" }` — the same
  OpenTofu adoption chosen to leave HashiCorp's terms behind still depends
  on a provider HashiCorp publishes, to configure OpenBao, the fork this
  platform adopted for the same licence reason (see
  [ADR-0011](0011-openbao-over-vault.md)). This record does not state what
  licence that provider currently ships under — confirming an external
  project's current licence terms is outside what this repository can
  verify about itself; see References for where to check directly.
  - *Mitigation*: none currently, and the exposure is scoped:
    `opentofu/aws/openbao/cluster/versions.tf`, the stack that provisions the
    actual Raft EC2 fleet, declares no `vault` provider at all — only
    `management`, which layers namespaces, the PKI and the auth policies on top,
    needs it.
- **Provider availability is not automatically identical to Terraform's.**
  OpenTofu's registry is a separate index from HashiCorp's; this
  repository's current provider set all resolves there today, but a
  provider whose maintainer does not explicitly publish for OpenTofu is not
  guaranteed to appear there, especially for anything less widely used than
  `hashicorp/aws` or `hashicorp/helm`.
  - *Mitigation*: none automated; a future stack reaching for an uncommon
    provider is a check to make before assuming OpenTofu compatibility, not
    after.

### Neutral

- Every stack's `required_version` constraint (`~> 1.4` in
  `openbao/management`, `~> 1.5` elsewhere, `>= 1.5` in `eks/configure`)
  predates this decision and was never edited — those ranges are satisfied
  by the pinned `opentofu = "1.12.6"` in `mise.toml` without any per-stack
  change.
- The CLI binary name itself changed (`tofu` instead of `terraform`);
  `opentofu/config.tm.hcl`'s `global.provisioner` is the one place that
  names it — today indirectly, via the `scripts/tm-provisioner.sh` wrapper it
  points at, whose last line execs `tofu` — so every Terramate script keeps
  calling `global.provisioner` regardless of which binary it resolves to.

---

## Implementation Notes

Adoption touched exactly two kinds of file: `mise.toml`, which pins the
`opentofu` tool version rather than a `terraform` one, and
`opentofu/config.tm.hcl`, whose `global.provisioner` (originally `"tofu"`
directly; now the `scripts/tm-provisioner.sh` wrapper, see the Update above)
is the value every script in `opentofu/workflows.tm.hcl` invokes. No stack's `versions.tf`
or resource HCL needed to change, and Terramate's own stack-ordering,
drift-detection and opt-in-gating behaviour — documented on
[Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — is
unaffected by any of this: it orchestrates whatever `global.provisioner`
names, not Terraform specifically.

The `hashicorp/vault` provider dependency in
`opentofu/aws/openbao/management/versions.tf` predates this decision — it
configures OpenBao regardless of which tool executes it — and is not
something adopting OpenTofu introduced or could remove on its own;
[ADR-0011](0011-openbao-over-vault.md) covers why OpenBao is configured
through that provider at all.

---

## References

- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) —
  "Why OpenTofu": the Linux Foundation governance and
  compatibility-with-existing-configuration claims this record's Context
  and Positive sections draw from
- [ADR-0011](0011-openbao-over-vault.md) — the same BUSL relicensing
  trigger, applied to Vault
- [ADR-0012](0012-crossplane-and-opentofu.md) — the boundary between
  OpenTofu and Crossplane assumed in this record's Context
- `mise.toml` — the `opentofu` tool pin and the absence of a `terraform`
  entry
- `opentofu/config.tm.hcl` — `global.provisioner`, pointing at
  `scripts/tm-provisioner.sh`, whose last line execs `tofu`
- `opentofu/workflows.tm.hcl` — the `init`, `preview`, `deploy`,
  `drift detect`, `drift reconcile` and `destroy` scripts that invoke
  `global.provisioner`
- `opentofu/aws/openbao/management/versions.tf` — the `hashicorp/vault`
  provider pin this record's Negative section names
- `opentofu/aws/openbao/cluster/versions.tf` — confirms the `vault` provider is
  absent from the cluster stack, scoping the dependency to `management`
  only
- [OpenTofu Registry](https://search.opentofu.org/) — where current
  provider publication for OpenTofu can be checked directly
- [`hashicorp/vault` provider on the Terraform Registry](https://registry.terraform.io/providers/hashicorp/vault/latest) —
  where that provider's current licence terms can be checked directly;
  this record does not assert them
