---
title: OpenBao is the store of record, durable as a snapshot lineage, active on the primary cloud with restore-based fallback
linkTitle: 0032 · OpenBao lineage
weight: 320
description: OpenBao's storage becomes derived state rebuilt from its newest Raft snapshot on every boot; what persists is a lineage — one multi-region KMS seal key, four bootstrap secrets, a snapshot bucket. One instance is active on AWS and serves both clusters; a GCP standby restores the mirrored snapshot under the same AWS seal. Chosen over per-cloud authoritative instances, an instance with no fallback, a Shamir-sealed standby, the clouds' managed CAs and cert-manager's CA issuer.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-09-02
**Deciders**: Smana (Platform Owner)
**Related Design**: `docs/superpowers/specs/2026-09-02-openbao-store-of-record-design.md` (repository path; designs are not published)
**Related**: [ADR-0025](0025-cloud-managed-secret-stores.md) — the cost record this
changes the mechanism of; [ADR-0027](0027-primary-cloud-provider.md) — the class
OpenBao moves into; [ADR-0011](0011-openbao-over-vault.md) — the engine

---

## Context

[ADR-0025](0025-cloud-managed-secret-stores.md) made the cloud's managed secret
store the store of record because it is always-on and outlives the platform,
and said OpenBao "remains the target" for a deployment that runs continuously.
Two facts, both verified on 2026-09-02, meant that target could never be
reached by leaving the process on:

- **The seal key was destroyed with the platform.** It lived in the ephemeral
  cluster stack with a 10-day deletion window, so every rebuild minted a new
  key and every earlier snapshot became ciphertext. `dev` mode ran the `file`
  backend and never took one, which is why nothing noticed.
- **The restore procedure was a documented hypothesis.** Nothing had ever
  executed it.

A store of record has to survive the platform. The insight is that *the running
process does not have to be what survives*. Everything a rebuilt OpenBao needs
to come back is small and cheap to keep: a seal key, the material that
bootstraps the node, and the newest snapshot. Call that a **lineage**, keep it
outside every ephemeral stack, and the process becomes derived state — off
between runs in the reference platform, always-on in production, the same
design either way.

## Decision Drivers

- **Cost of the idle floor.** ADR-0025's constraint is real: the reference must
  not pay for an always-on secrets cluster. It may pay ~$1/month for a key.
- **Restorability, proven.** Every deploy of the reference platform and a weekly
  drill must exercise the restore path.
- **One root of trust, offline.** The AWS root private key sat inside the live
  PKI mount; GCP had already fixed that with an offline root.
- **No long-lived credential to reach OpenBao.** Workloads authenticate with
  their cluster's ServiceAccount tokens.
- **A fallback that survives an AWS regional outage**, stated with its limits.
- **GCP-only deployments keep working with no AWS dependency**
  ([ADR-0024](0024-identity-provider-per-cloud.md)).

## Considered Options

### Option 1: Managed stores remain the store of record (status quo)

**Pros**: nothing to build. **Cons**: the platform documents a target it does
not run; the seal-key and restore defects stay; two stores with a placement
rule to learn.

### Option 2: Per-cloud OpenBaos, each authoritative for its cluster

**Pros**: no cross-cloud dependency. **Cons**: a value both clouds need is
seeded twice and drifts (ADR-0025's own negative); two policy models; two roots
of trust or a shared root with two issuing chains and no single audit trail.

### Option 3: One OpenBao, no fallback

**Pros**: simplest. **Cons**: a GCP-only platform cannot authenticate to
anything, which is the dependency ADR-0024 removed for the identity provider.

### Option 4: One active OpenBao on the primary cloud, a snapshot lineage, a standby restoring under the same seal *(chosen)*

**Pros**: one store, one policy model, one root; the floor moves by one key;
restore is exercised on every deploy; fallback survives a regional outage.
**Cons**: the standby depends on AWS KMS (mitigated by a multi-region replica);
a bootstrap tier of four secrets per cloud remains in the managed stores; new
cross-cloud plumbing (Tailscale egress, two federated roles).

### Rejected on the seal: a Shamir-sealed standby

Survives the loss of the AWS account, but every restart becomes a human typing
a key share and Raft auto-join breaks. Seal migration during failover is not an
option either: it requires both seals reachable, which an outage denies.

### Rejected on the PKI: AWS Private CA / GCP CAS, and cert-manager's CA issuer

The clouds' managed CAs cost about $400/month per CA on AWS and are not
portable. cert-manager's built-in CA issuer costs nothing but keeps the
intermediate key in a Kubernetes Secret and removes the self-hosted PKI this
repository exists to demonstrate.

### Rejected earlier: SOPS

ADR-0025, option 3.

## Decision Outcome

**Option 4.** OpenBao is the store of record. Its durable form is the lineage:
`alias/openbao-seal` (multi-region, replica in `eu-west-1`), the snapshot
bucket and its key, and four bootstrap secrets per cloud (server TLS material,
root token, recovery keys, the offline-signed intermediate). The process is
rehydrated from the newest snapshot on every boot; a last snapshot is taken
before every destroy. One instance is active on AWS
([ADR-0027](0027-primary-cloud-provider.md) primary-cloud singleton — OpenBao
changes class from *per-cloud*, with the one property the other singletons lack:
its relocation carries state). Workloads on both clusters authenticate through
the JWT method against their cluster's OIDC issuer. One offline root signs one
intermediate per lineage. A GCP standby restores the GCS mirror sealed by the
same AWS key through OIDC federation; the fallback survives an AWS regional
outage and the loss of AWS compute or Secrets Manager, **not** the loss of the
AWS account — a deliberate trade for keeping auto-unseal.

Staged: Stage 1 builds the lineage, rehydrate, JWT auth, the offline root on
AWS, the mirror, the drill and one executed cross-cloud failover, with the
managed store still the store of record. Stage 2 repoints the
`ClusterSecretStore` and migrates about 36 secrets.

## Consequences

### Positive

- The idle floor moves from about $23 to about $24/month, and the platform runs
  the design it documents.
- Restore stops being a hypothesis: every deploy performs one, and CI drills it
  weekly with no recovery keys in reach.
- No AppRole `SecretID` exists anywhere; the two AppRole entries per cloud are
  gone from the managed stores.
- Tailnet clients trust one root, and no CA private key is on a networked system.

### Negative

- The standby is coupled to AWS KMS. *Mitigation*: multi-region replica; the
  limit is stated in the failover guide.
- Four bootstrap secrets per cloud must exist on both clouds for a fallback to be
  bootstrappable; they are seeded by hand and can drift. *Mitigation*: the list
  is short and `secret-store.sh check` names what is missing.
- New moving parts: a systemd timer refreshing a web-identity token on the GCP
  node, a Storage Transfer job, an egress `ProxyGroup` path, two federated roles.
- A node recreated between snapshots loses writes since the last one (RPO = the
  snapshot cadence: daily in the reference, hourly in production).

### Neutral

- ADR-0025's cost constraint is unchanged; it now bounds whether the process is
  left on between runs, not where the store of record is.
- The `ClusterSecretStore` repoint (Stage 2) is the change ADR-0025 always said
  it would be.

## Implementation Notes

Stage 1 plan: `docs/superpowers/plans/2026-09-02-openbao-store-of-record-stage1.md`.
Lineage stacks: `opentofu/aws/openbao/lineage/`, `opentofu/gcp/openbao/lineage/`.
Rehydrate: `scripts/openbao-config.sh rehydrate`, called by both management
stacks' deploy scripts. Auth mounts: `opentofu/{aws/eks,gcp/gke}/configure/openbao.tf`.
Fallback runbook: [Cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).

## References

- [ADR-0025](0025-cloud-managed-secret-stores.md), [ADR-0027](0027-primary-cloud-provider.md), [ADR-0024](0024-identity-provider-per-cloud.md), [ADR-0019](0019-cross-cloud-dns-federation.md)
- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}), [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}), [What it costs]({{< relref "/docs/get-started/costs.md" >}})
- OpenBao docs: seal migration requires both seals reachable; Raft nodes must share a seal configuration
