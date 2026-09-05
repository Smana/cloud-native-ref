---
title: Cloud-managed secret stores as the store of record, OpenBao scoped to the PKI
linkTitle: 0025 · Managed secret stores
weight: 250
description: Platform secrets live in AWS Secrets Manager / GCP Secret Manager rather than OpenBao, because the store of record must be always-on and outlive the platform, and this reference cannot afford a long-running self-hosted instance — OpenBao remains the target, scoped today to the private PKI and the tenancy model.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-08-27
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a standing architecture choice
**Related**: [ADR-0011](0011-openbao-over-vault.md) — which engine backs the
self-hosted role; [ADR-0023](0023-portable-secret-store-names.md) — the name
grammar that keeps the store swappable

---

{{< callout type="info" >}}
**Amended 2026-09-02 by [ADR-0033](0033-openbao-store-of-record-lineage.md).**
The constraint recorded below is unchanged: this reference cannot afford an
always-on OpenBao. What changed is what the constraint bounds. OpenBao's storage
is now derived from a *lineage* — a persistent seal key, five bootstrap secrets
and a snapshot bucket — and rehydrated on every boot, so the process can be off
between runs while OpenBao is the store of record. The "Neutral" sentence below
saying OpenBao remains the target is therefore no longer aspirational; the
`ClusterSecretStore` repoint it describes is Stage 2 of ADR-0033's plan. Until
that stage lands, the placement rule in this record still describes the live
platform.
{{< /callout >}}

## Context

Every credential this platform consumes resolves through External Secrets
Operator from a single `ClusterSecretStore`
(`security/aws-0/openbao/clustersecretstore.yaml`) — and that store is
the **cloud's managed secret manager**: AWS Secrets Manager on `aws-0`, GCP
Secret Manager on `gcp-0`. OpenBao, the platform's self-hosted secrets engine,
holds none of them. It owns the private PKI and a worked example of
namespace-scoped tenant secrets, nothing more.

That looks backwards for a platform that ships its own secrets engine, so the
reasoning deserves a record. The store of record for platform secrets has two
hard requirements the platform itself cannot meet:

- **It must be always-on.** The whole platform depends on these secrets —
  Flux's GitHub App credentials, OpenBao's own root token and unseal material,
  every AppRole `SecretID`, operator passwords. A secrets outage is a platform
  outage, and several of these are consumed *at bootstrap*, before any
  self-hosted component exists to serve them.
- **It must outlive the platform.** This reference environment is torn down
  and rebuilt routinely; the secrets that rebuild it have to survive the
  teardown. A store that lives inside the blast radius of what it
  bootstraps cannot be the store of record — the same principle
  [ADR-0018](0018-per-cloud-opentofu-state.md) applies to OpenTofu state.

Meeting both with OpenBao would mean a highly-available cluster running
permanently, independent of the platform's own lifecycle. For this
reference — deployed for hours or days at a time, on a personal budget — a
long-running self-hosted instance is exactly the cost the rest of the
platform is engineered to avoid. A managed secret store is always-on for
cents per secret per month, with no instance to operate at all.

There is also a circularity no amount of budget removes: OpenBao's own
bootstrap material — root token, recovery keys, the offline-signed
intermediate — cannot live in OpenBao. A still-sealed cluster cannot serve
the keys that unseal it. Some managed store was always going to hold that
material; the question is only how much else it holds.

---

## Decision Drivers

- **Availability decoupled from the platform lifecycle** — secrets must be
  readable while the platform is down, being rebuilt, or not yet deployed.
- **Cost** — this reference cannot justify an always-on, highly-available
  self-hosted cluster whose only job is to hold a few dozen secrets.
- **Bootstrap ordering** — the store must exist before the first OpenTofu
  stack runs, with nothing to operate or unseal first.
- **Keeping OpenBao's lesson intact** — the self-hosted PKI and the
  namespace/AppRole tenancy model are things this repository exists to
  demonstrate ([ADR-0011](0011-openbao-over-vault.md)).
- **Reversibility** — the target architecture remains OpenBao; the deviation
  should stay cheap to undo.

---

## Considered Options

### Option 1: Cloud-managed secret stores as store of record; OpenBao scoped to the PKI

AWS Secrets Manager / GCP Secret Manager hold every platform secret,
delivered into the cluster by External Secrets through the one
`ClusterSecretStore`. OpenBao runs only while the platform runs, owning the
private PKI (`pki_private_issuer`) and the namespaced AppRole tenancy model.

**Pros**:
- Always-on and durable for cents, with zero instances to operate — secrets
  survive every teardown, and a rebuild reads them back with plain IAM.
- No bootstrap circularity: the store pre-exists the first `tofu apply` and
  authenticates with the same cloud credentials the deploy already needs.
- Workloads authenticate with the platform's native identity path (EKS Pod
  Identity / Workload Identity) — no token ceremony before the first secret.

**Cons**:
- A vendor-managed dependency at the heart of an otherwise open-source
  platform — the pattern is portable (both clouds have an equivalent), but
  the store itself is not self-hosted.
- Two stores to reason about: "is this in Secrets Manager or in OpenBao?"
  has a rule (everything except PKI material and tenant mounts), but it is
  a rule newcomers must learn.
- Per-cloud store semantics leak into shared manifests — the name grammar
  had to be restricted to what both stores accept
  ([ADR-0023](0023-portable-secret-store-names.md)).

### Option 2: OpenBao as store of record for everything

The target architecture: one always-on, highly-available OpenBao cluster
(five-node Raft, `mode = "ha"`) holding platform secrets and the PKI, with
`ClusterSecretStore` pointing at it.

**Pros**:
- One store, one audit trail, one access-control model — and it is the
  open-source, self-hosted one this platform would prefer to demonstrate
  end to end.
- Namespaces and AppRole policies give tenancy semantics a flat managed
  store cannot express.

**Cons**:
- Requires an instance that runs 24/7 regardless of whether the platform
  does — compute, storage, snapshots, patching, and monitoring for a
  component whose availability now gates everything else. Unaffordable for
  this reference, and disproportionate to its secret count.
- The circularity remains regardless: OpenBao's own unseal and bootstrap
  material still needs a store that precedes it, so a managed store exists
  in every variant of this architecture anyway.
- Makes the always-on OpenBao a single point of failure spanning both
  clouds, or doubles the cost by running one per cloud.

### Option 3: Encrypted secrets in Git (SOPS / sealed-secrets)

No runtime store at all: encrypt secrets into the repository and decrypt at
reconcile time.

**Pros**:
- Nothing to run and nothing to pay for; secrets versioned with the code
  that consumes them.

**Cons**:
- Rotation and revocation become Git operations — no TTLs, no dynamic
  credentials, no single place to audit access.
- Still needs a KMS key per cloud to decrypt, so the managed-service
  dependency does not actually disappear.
- Abandons the External Secrets model the constitution standardises on,
  and with it the ability to repoint one `ClusterSecretStore` at OpenBao
  later — the opposite of keeping the target architecture cheap to reach.

---

## Decision Outcome

**Chosen option**: "Option 1 — cloud-managed secret stores as store of
record, OpenBao scoped to the PKI"

**Rationale**: This is a cost- and lifecycle-driven deviation from the
target, not a preference. The store of record must be always-on and must
outlive the platform; the only component that satisfies both without a
permanent self-hosted footprint is the cloud's managed store, which this
platform already needs for OpenBao's own bootstrap material. OpenBao keeps
the roles that actually need a self-hosted engine — the private PKI and the
namespace/AppRole tenancy model — so the reference still demonstrates them.
The migration path back to the target stays deliberately short: every secret
reaches the cluster through External Secrets, so adopting OpenBao as store
of record is repointing the `ClusterSecretStore`, not rewriting consumers —
which is also why [ADR-0023](0023-portable-secret-store-names.md)'s portable
name grammar matters beyond GCP.

---

## Consequences

### Positive

- Platform secrets survive every teardown and are readable before the first
  stack applies — rebuilds need cloud credentials and nothing else.
- No always-on self-hosted infrastructure: the platform's idle cost for
  secrets is the managed store's per-secret pricing, effectively noise.
- OpenBao's lifecycle is free to match the platform's: it deploys with it,
  is torn down with it, and its Raft snapshots land in the cloud store's
  blast-radius-separated object storage.

### Negative

- The platform's most security-sensitive dependency is vendor-managed. The
  *pattern* is portable across clouds, but anyone forking this repository
  onto infrastructure without a managed secret store must solve Option 2's
  cost problem first.
  - *Mitigation*: the External Secrets seam — swapping the backing store is
    a `ClusterSecretStore` change, not a consumer rewrite.
- Secrets are duplicated per cloud with no replication between AWS Secrets
  Manager and GCP Secret Manager: a value that must exist on both (the
  GitHub App credentials, CA material) is seeded twice and can drift.
  - *Mitigation*: none automated today; the seeding steps are documented in
    each lane's prerequisites.
- Two stores mean a placement rule to learn: PKI material and tenant mounts
  in OpenBao, everything else in the managed store.

### Neutral

- OpenBao remains the **target** store of record for a deployment of this
  platform that runs continuously — the day the platform is always-on, the
  cost argument inverts, and the migration is the `ClusterSecretStore`
  repoint described above.
- This record makes explicit what [ADR-0011](0011-openbao-over-vault.md)
  treated as a neutral observation: the coexistence of the two stores is
  the architecture, not an incomplete migration.

---

## Implementation Notes

`security/aws-0/openbao/clustersecretstore.yaml` defines the AWS
Secrets Manager store every `ExternalSecret` on `aws-0` names;
`security/gcp-0/openbao/clustersecretstore.yaml` is its `gcp-0` sibling,
backed by GCP Secret Manager. Neither derives from the other — the two
providers share no fields worth factoring into a base. Both authenticate through the cloud's native
workload identity (EKS Pod Identity / Workload Identity) — no static store
credential exists. OpenBao's scope — the `pki_private_issuer` mount, the
AppRoles, the `app` tenant namespace — is provisioned by
`opentofu/{aws,gcp}/openbao/management/`.

---

## References

- [ADR-0011](0011-openbao-over-vault.md) — why the self-hosted engine is
  OpenBao, and the coexistence note this record promotes to a decision
- [ADR-0023](0023-portable-secret-store-names.md) — the portable name
  grammar that keeps the store of record swappable
- [ADR-0018](0018-per-cloud-opentofu-state.md) — the same
  outside-the-blast-radius principle, applied to OpenTofu state
- [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}})
  — how External Secrets and cert-manager consume the two stores
- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}) — what the
  self-hosted engine owns: namespaces, AppRoles, the PKI
- `security/aws-0/openbao/clustersecretstore.yaml` — the AWS store
  of record; `security/gcp-0/openbao/clustersecretstore.yaml` — the GCP
  override
