---
title: Use OpenBao rather than HashiCorp Vault
linkTitle: 0011 · OpenBao over Vault
weight: 110
description: Secrets and the private PKI run on OpenBao, the Linux Foundation fork, after HashiCorp relicensed Vault under the BUSL — accepting a smaller ecosystem and a 2.6 write-concurrency deadlock worked around with serialised applies.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow
**Related**: [ADR-0014](0014-opentofu-over-terraform.md) — the same
licence trigger, applied to the toolchain

---

## Context

This platform needs a self-hosted secrets engine and a private PKI: the
three-tier certificate chain that terminates TLS on every internal Gateway
API listener, and the machine authentication `cert-manager` and the Raft
snapshot job use to reach it. That role is filled by OpenBao,
not HashiCorp Vault, the project OpenBao forked from.

HashiCorp originally published Vault under the Mozilla Public License 2.0.
In 2023 it relicensed Vault, and its other tools, under the Business
Source License (BUSL) — source-available, not open source: running a
BUSL-licensed component as a competing hosted offering needs a commercial
agreement with HashiCorp, and each release only becomes fully open again
after a fixed embargo period. OpenBao is the response: a fork of the last
MPL-2.0 Vault codebase, contributed to and now governed by the Linux
Foundation, continuing under the original permissive licence.

This is not the platform's only secrets store. External Secrets
Operator's `ClusterSecretStore`
(`security/aws-0/openbao/clustersecretstore.yaml`) already reads
from AWS Secrets Manager, and even OpenBao's own bootstrap material — the
server certificate, the root token, the recovery keys, the operator password,
the offline-signed intermediate — is published there rather than kept inside
OpenBao itself, since a still-sealed or freshly-initialised cluster cannot be
the thing that stores the keys to unseal it. What OpenBao specifically owns is
the private PKI and the namespace-scoped tenancy model: the root namespace
hosts the PKI mount and the per-cluster JWT auth mounts, while `app` is a
worked example of a tenant namespace holding its own `secret/` mount and
AppRole. This decision is about which engine backs that role, not about the
platform's secrets architecture as a whole.

---

## Decision Drivers

- **Licence continuity.** A reference platform meant to be cloned and run
  by anyone should not depend on a component whose commercial terms one
  vendor can change under it — avoiding that kind of licence cliff is a
  standing principle behind several of this platform's other choices.
- **Migration cost.** Whatever replaces Vault has to work with the
  Terraform/OpenTofu code already written against it — `vault_*`
  resources, the `hashicorp/vault` provider, the `bao`/`vault` CLI
  surface.
- **Self-hosted PKI and a namespaced tenancy model.** The chosen engine has
  to support namespaces as tenancy boundaries and role-scoped policies
  for machine authentication, not just a flat key-value store.
- **Fit with what AWS Secrets Manager already covers**, so the decision
  stays scoped to what OpenBao actually needs to do, not a rewrite of the
  platform's whole secrets architecture.

---

## Considered Options

### Option 1: OpenBao

The Linux Foundation fork of the last MPL-2.0 Vault codebase. Provisioned
as two stacks: `opentofu/aws/openbao/cluster/` stands up the EC2 fleet — one
Raft node as committed, or a five-node Raft cluster at `mode = "ha"` — and
`opentofu/aws/openbao/management/` layers namespaces, the PKI and the auth
policies on top through the `hashicorp/vault` OpenTofu provider.

**Pros**:
- Stays under a permissive open-source licence with neutral governance,
  instead of a vendor-controlled source-available one.
- API-compatible enough that the existing `hashicorp/vault` OpenTofu
  provider configures it unmodified
  (`opentofu/aws/openbao/management/versions.tf`) — the Terraform/OpenTofu
  code written against Vault's API needed no rewrite to target OpenBao.
- Same `bao`/`vault` CLI surface and Raft storage backend, so the
  namespace, AppRole and PKI model this platform depends on ported
  directly.

**Cons**:
- Smaller ecosystem than Vault: fewer third-party integrations, less
  community documentation, fewer people to ask when something breaks.
- Younger project still finding its own operational rough edges — see
  Consequences.

### Option 2: Stay on Vault under the BUSL

Keep HashiCorp Vault, accepting the relicensing rather than migrating.

**Pros**:
- Larger ecosystem, more mature tooling, and official commercial support
  available if the platform ever needed it.
- No migration effort at all — this is the status quo, and the existing
  Terraform code already targets Vault's real API.

**Cons**:
- Runs the exact licence risk this decision exists to avoid: a
  source-available dependency whose commercial terms HashiCorp controls
  unilaterally, on a component this platform would depend on
  indefinitely.
- Undercuts the point of a reference platform — someone cloning this repo
  to learn from or build on shouldn't have to first evaluate whether
  running Vault this way trips the BUSL's competing-offering clause.
- The "no migration" advantage is smaller than it looks: OpenBao's API
  compatibility with Vault is precisely why Option 1 is not a rewrite
  either, so staying on Vault buys almost nothing beyond avoiding the
  switch itself.

### Option 3: AWS Secrets Manager + AWS Private CA only

Drop the self-hosted secrets engine entirely: keep using AWS Secrets
Manager for what External Secrets Operator already pulls from it, and
move the private PKI to AWS Private CA (ACM PCA) instead of OpenBao's
`pki_private_issuer` mount. Not a strawman — the platform already runs
half of this: `ClusterSecretStore` reads from AWS Secrets Manager today,
and OpenBao's own bootstrap secrets live there too.

**Pros**:
- Nothing to operate: no Raft cluster, no `bao operator init`/unseal
  choreography, no EC2 fleet to patch.
- Fully IAM-native — AWS Private CA issuance and Secrets Manager reads
  would both be authorised the same way every other AWS-managed
  dependency on this platform is, via EKS Pod Identity.

**Cons**:
- Recurring per-CA, per-certificate cost for AWS Private CA, in place of
  a cost this platform currently pays once, as EC2 capacity, regardless
  of how many certificates it issues.
- Loses the namespace-scoped, policy-authenticated tenancy model — `app`
  as a worked example of a self-service tenant secrets mount has no
  equivalent shape in Secrets Manager, which is a flat, IAM-policy-scoped
  store, not a namespaced one.
- Removes the one self-hosted PKI/secrets-engine reference implementation
  this platform demonstrates, in favour of a fully managed AWS
  dependency — a legitimate choice for a production platform, but a
  narrower lesson than a reference repo aims to teach.

---

## Decision Outcome

**Chosen option**: "Option 1 — OpenBao"

**Rationale**: The trigger is licence, not technical superiority. Option 1
wins over Option 2 because a reference platform anyone can clone and run
should not carry a source-available dependency whose terms one vendor can
change, and OpenBao removes that risk for essentially no migration cost —
the same Terraform code, the same provider, the same CLI. Option 3 is a
real, partially-adopted alternative: this platform already uses AWS
Secrets Manager for everything External Secrets delivers. But going
further and dropping the self-hosted PKI and namespace model would trade
a one-time infrastructure cost for a recurring per-certificate one, and
would remove the self-hosted-secrets pattern this repository exists to
demonstrate.

---

## Consequences

### Positive

- Secrets management and the private PKI stay on a permissively-licensed,
  neutrally-governed codebase, with no single vendor able to change the
  commercial terms this platform depends on.
- The `hashicorp/vault` OpenTofu provider configures OpenBao unmodified,
  so every `vault_*` resource in `opentofu/aws/openbao/management/` needed no
  rewrite to target it.
- OpenBao's role stays narrow and complementary rather than duplicating
  AWS Secrets Manager: the private PKI and namespace-scoped machine auth
  live in OpenBao, while External Secrets Operator's
  `ClusterSecretStore` keeps delivering bulk application secrets from AWS
  Secrets Manager.

### Negative

- **Smaller ecosystem than Vault.** Upstream integrations, Helm charts
  and documentation across the wider ecosystem still assume Vault by
  default; OpenBao-specific gaps get filled by this platform's own docs
  rather than found ready-made upstream.
  - *Mitigation*: none automated; OpenBao's API compatibility with Vault
    means most Vault-oriented troubleshooting knowledge still transfers
    even where the tooling itself doesn't reference OpenBao by name.
- **The 2.6 line carries a write-concurrency deadlock this platform hits
  on every `tofu apply`.**
  [openbao/openbao#3411](https://github.com/openbao/openbao/issues/3411)
  (inconsistent lock ordering between the core mounts lock and the
  namespace lock, still open upstream) wedges the core when the
  management stack writes namespaces, auth backends and mounts
  concurrently on a small node — `bao status` then hangs even against
  `127.0.0.1`, which is a core deadlock, never a VPN problem.
  - *Mitigation*: `-parallelism=1` on the management stack's `apply` and
    `destroy` in `opentofu/aws/openbao/management/workflows.tm.hcl`, marked
    in-code as load-bearing rather than caution. This serialises the
    stack's own writes; it is not a version pin, and it does not require
    staying off the 2.6 line.
- **The root CA private key lives in the live `pki_private_issuer` mount, not
  offline.** **Decided against on 2026-09-02 by
  [ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}}) —
  and not yet undone on AWS.** The mount signed the intermediate's CSR inside
  OpenBao (`vault_pki_secret_backend_root_sign_intermediate`) so the deploy
  stayed unattended, which put the root key on a networked system.
  `opentofu/aws/openbao/management/pki.tf` now imports an intermediate the
  offline root signed out of band instead — but the signing ceremony that
  produces that intermediate (**Task 14** of the Stage 1 plan) and the deletion
  of `certificates/priv.aws.ogenki.io/root-ca` (**Task 17 Step 2**) are both
  hand-performed and neither has run. So on AWS the root key is still in the
  mount and still in Secrets Manager; on GCP it has been offline since
  2026-08-25, and Task 14 is what makes the two clouds chain to the *same*
  offline root. See
  [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}).
  - *Mitigation as recorded at the time, and still the live one*: none beyond
    documenting the trade-off; a deployment where the root CA's confidentiality
    matters needs an offline root, which means giving up the unattended-deploy
    property this platform trades for it.

### Neutral

- AWS Secrets Manager still holds OpenBao's own bootstrap material — the CA
  chain, the server certificate, the root token, the recovery keys, the operator
  password, and the offline-signed intermediate. This is not an incomplete
  migration to OpenBao; a still-sealed cluster cannot be where its own unseal
  material lives, so the two stores were always going to coexist for that
  specific material. [ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}})
  names that set the *lineage* and makes everything else derived from a
  snapshot.
- The root namespace hosts every shared platform service — the PKI mount and
  the per-cluster JWT auth mounts — while `app` is the only tenant namespace
  defined today, holding an otherwise-unconsumed `secret/` mount and the one
  remaining AppRole. Namespaces are a tenancy boundary this platform has built
  but not yet exercised beyond the one worked example.

---

## Implementation Notes

`opentofu/aws/openbao/cluster/` provisions the EC2 fleet and pins
the OpenBao release (`openbao_version` in `variables.tf`, currently on
the 2.6 line); `opentofu/aws/openbao/management/` layers namespaces, the PKI
and the auth policies on top through the `hashicorp/vault` provider,
and is the stack the `-parallelism=1` mitigation applies to. The provider
name is unchanged from the Vault-era code —
`required_providers { vault = { source = "hashicorp/vault" } }` — because
OpenBao's HTTP API, not a HashiCorp-specific product name, is what the
provider actually targets.

Operator access, namespace layout and the JWT machine-auth pattern
are documented in full on
[OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}).

---

## References

- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) —
  namespace layout, operator login, JWT machine auth, backup/restore,
  and the 2.6.x concurrency constraint this record's Negative section
  draws from
- [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}})
  — the three-tier certificate chain and the one offline root both clouds
  chain to
- [CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md)
  — the OpenBao command reference and namespace-layout summary under
  "OpenBao"
- `opentofu/aws/openbao/management/versions.tf` — the `hashicorp/vault`
  provider pin that configures OpenBao
- `opentofu/aws/openbao/cluster/variables.tf` — the `openbao_version` pin and
  the in-code explanation of the 2.6.x deadlock
- `opentofu/aws/openbao/management/workflows.tm.hcl` — the `-parallelism=1`
  mitigation and its reproduction notes
- `security/aws-0/openbao/clustersecretstore.yaml` — the AWS
  Secrets Manager `ClusterSecretStore` that External Secrets Operator
  reads from, alongside OpenBao
- [openbao/openbao#3411](https://github.com/openbao/openbao/issues/3411)
  — the open upstream lock-ordering bug behind the `-parallelism=1`
  workaround
