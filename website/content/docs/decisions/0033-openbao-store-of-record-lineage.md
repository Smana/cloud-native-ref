---
title: OpenBao is the store of record, durable as a snapshot lineage, active on the primary cloud with restore-based fallback
linkTitle: 0033 · OpenBao lineage
weight: 330
description: OpenBao's storage becomes derived state rebuilt from its newest Raft snapshot on every boot; what persists is a lineage — one multi-region KMS seal key, five bootstrap secrets, a snapshot bucket. One instance becomes active on AWS and serves both clusters; a GCP standby restores the mirrored snapshot under the same AWS seal. Stage 1 is per-cloud; Stage 2 converges it. Chosen over per-cloud authoritative instances, an instance with no fallback, a Shamir-sealed standby, the clouds' managed CAs and cert-manager's CA issuer.
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
- **One root of trust, offline.** The AWS root private key used to sit inside the
  live PKI mount. Taking it out is a hand-performed ceremony, and it has now been
  performed: the root signs per-cloud intermediates offline, only the intermediate
  bundle enters a networked store, and the root certificate is committed as
  `.github/openbao-root-ca.pem` so the drill can verify against it. Both clouds
  now match. The procedure is on the
  [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}) page.
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

Rejected as a **reduction** of that drift surface, not its removal. The chosen
option's own Negatives concede a residual hand-seeded tier of five secrets per
cloud, and Stage 1 leaves each cloud with its own lineage, bucket, intermediate
and JWT mount — so what Option 2 loses is the *convergence*, not the last
duplicated value.

### Option 3: One OpenBao, no fallback

**Pros**: simplest. **Cons**: a GCP-only platform cannot authenticate to
anything, which is the dependency ADR-0024 removed for the identity provider.

### Option 4: One active OpenBao on the primary cloud, a snapshot lineage, a standby restoring under the same seal *(chosen)*

**Pros**: one store, one policy model, one root; the floor moves by one key;
restore is exercised on every deploy; fallback survives a regional outage.
**Cons**: the standby depends on AWS KMS (mitigated by a multi-region replica);
a bootstrap tier of five secrets per cloud remains in the managed stores; new
cross-cloud plumbing (Tailscale egress, two federated roles).

### Rejected on the seal: a Shamir-sealed standby

Survives the loss of the AWS account, but every restart becomes a human typing
a key share and Raft auto-join breaks. Seal migration during failover is not an
option either: it requires both seals reachable, which an outage denies.

### Rejected on the PKI: AWS Private CA / GCP CAS, and cert-manager's CA issuer

The clouds' managed CAs cost about $400/month per CA on AWS and are not
portable.

cert-manager's built-in CA issuer costs nothing, and is rejected for what it
would remove rather than for where it stores a key: it replaces the self-hosted
PKI — mounts, roles, policies, an audited issuing path — that this repository
exists to demonstrate, and it has no answer for the non-certificate half of
OpenBao's job. "It keeps the intermediate key in a Kubernetes Secret" is *not*
the honest discriminator, because the chosen option keeps that same key in a
networked secret store too (`certificates/priv.aws.ogenki.io/intermediate-ca`)
and imports it into the live mount. The real difference is blast radius, not
kind: a Kubernetes Secret is readable by anything with `get secrets` in that
namespace and by any workload that mounts it, and it is snapshot into etcd
backups; the Secrets Manager entry is reachable only by the OpenTofu principal
that runs the management stack, is IAM-auditable per read, and is never
projected into a pod. Both are networked. One has a smaller and more legible
set of readers.

### Rejected earlier: SOPS

ADR-0025, option 3.

## Decision Outcome

**Option 4.** OpenBao is the store of record. Its durable form is the lineage:
`alias/openbao-seal` (multi-region, replica in `eu-west-1`), the snapshot
bucket and its key, and five bootstrap secrets per cloud (the CA chain, server
TLS material, root token, recovery keys, the offline-signed intermediate — the
CA chain is read first, before rehydrate, on every deploy). The process is
rehydrated from the newest snapshot on every boot; a last snapshot is taken
before every destroy. One instance becomes the active one, on AWS
([ADR-0027](0027-primary-cloud-provider.md) primary-cloud singleton — OpenBao
changes class from *per-cloud*, with the one property the other singletons lack:
its relocation carries state). Workloads on both clusters authenticate through
the JWT method against their cluster's OIDC issuer. One offline root signs one
intermediate per lineage. A GCP standby restores the GCS mirror sealed by the
same AWS key through OIDC federation; the fallback survives an AWS regional
outage and the loss of AWS compute or Secrets Manager, **not** the loss of the
AWS account — a deliberate trade for keeping auto-unseal.

Staged, and the staging matters for what a reader should expect to find on the
clusters. **Stage 1 is per-cloud.** It builds the lineage, rehydrate, JWT auth,
the offline root on AWS, the mirror, the drill and one executed cross-cloud
failover — while leaving in place:

- **Two OpenBao instances, each authoritative for its own cluster.** `jwt/gcp-0`
  is created against `https://bao.priv.gcp.ogenki.io:8200`
  (`opentofu/gcp/gke/configure/openbao.tf`, whose `vault` provider addresses the
  GCP node), and `security/gcp-0/openbao/kustomization.yaml` lists
  `openbao-endpoint/local`. `gcp-0` reaches its own cloud's OpenBao in the
  normal posture; nothing routes it to the AWS instance.
- **A lineage, snapshot bucket and intermediate CA per cloud**, with the
  hand-seeded bootstrap tier duplicated on both.
- **The managed store still the store of record.**

So "one instance active on AWS serving both clusters" is the decision's end
state, not Stage 1's. Stage 2 is what converges it: it repoints the
`ClusterSecretStore` and migrates about 36 secrets, and it is also where `gcp-0`
switches to the remote endpoint form and stops being authoritative for itself.
Until then the two clouds run the same design twice, which is why the residual
drift in the Negatives below is real rather than theoretical.

## Consequences

### Positive

- The idle floor moves from about $23 to about $24/month, and the platform runs
  the design it documents. The added dollar is the seal key's `eu-west-1`
  replica, which KMS bills as a key of its own; confirmed on the live account
  once the lineage stack was applied. The buckets are rounding error at 74 KB
  per snapshot.
- Restore stops being a hypothesis: every deploy performs one, and CI drills it
  weekly with no recovery keys in reach.
- No AppRole `SecretID` exists anywhere; the two AppRole entries per cloud are
  gone from the managed stores.
- Tailnet clients trust one root, and no **root** CA private key is on a
  networked system. The *intermediate's* private key still is: it lives in
  `certificates/priv.aws.ogenki.io/intermediate-ca` in AWS Secrets Manager
  (`openbao-priv-gcp-intermediate-ca` on GCP) and is imported into the live PKI
  mount by `opentofu/aws/openbao/management/pki.tf`. That is the tier this
  design moves off a networked system, and the tier it does not.

### Negative

- The standby is coupled to AWS KMS. *Mitigation*: multi-region replica; the
  limit is stated in the failover guide.
- Five bootstrap secrets per cloud must exist on both clouds for a fallback to be
  bootstrappable; they are seeded by hand and can drift. *Mitigation*: the list
  is short, and the failover guide's
  [preconditions]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}})
  enumerate all five with the code that reads each one, as peacetime checks with
  the commands to run them.

  **`secret-store.sh check` does not cover this tier, and cannot.** Its
  `cmd_check` enumerates keys by reading `externalsecrets.external-secrets.io -A`
  from a **live cluster** and resolving only `spec.data[].remoteRef.key` and
  `spec.dataFrom[].extract.key`. Of the five, exactly one — the CA chain — is
  named by any of those fields. The root token, recovery keys, intermediate CA
  and server certificate are read by OpenTofu providers and boot scripts, so ESO
  never names them at all and `check` cannot see them. It also needs a running cluster
  with External Secrets installed, which is exactly what a fallback bootstrap
  does not have.
- **The GCP snapshot bucket becomes a mixed-seal namespace during a failover.**
  Once a standby has run under `awskms`, both the mirrored objects and its own
  are AWS-sealed, and a `gcpckms` node cannot unwrap any of them. That much is
  inherent to the design and is still true.

  *As accepted on 2026-09-02*, the consequence was sharper than that: those
  objects were **indistinguishable by name**. `openbao-snapshot.sh` wrote every
  one as `<timestamp>.snap` — flat, identical on both clouds — so nothing in a
  name, and nothing `latest_snapshot()` read, recorded which seal had wrapped
  it; the selector simply picked the newest. A later `gcpckms` node therefore
  selected a snapshot it could not unwrap, restored it, and stranded itself
  holding throwaway keys. The mitigation was procedural: the failover guide's
  failback destroyed the standby with `TM_OPENBAO_SKIP_SNAPSHOT=true` rather
  than flipping its seal, and asked an operator to move the AWS-sealed objects
  aside — or promote the last `gcpckms`-era object by name — before `gcp-0`
  returned to GCP-only mode. This record named the code-level fix that would
  remove it, "a seal segment in the key, or a `seal=` object attribute
  `latest_snapshot()` filters on", and deferred it: *not done in Stage 1; the
  first thing to do if a second failover is ever expected.*

  **Amended 2026-09-02 — closed the same day, by the first of those two.**
  Objects are now written `<UTC timestamp>-<seal>.snap`, e.g.
  `2026-09-02T041500Z-awskms.snap`. The seal is read from the writing node's own
  unauthenticated `/v1/sys/seal-status` rather than from configuration, so it
  records what actually wrapped the bytes; the timestamp stays leading and
  fixed-width, so lexicographic order remains chronological across seals. Both
  selection paths — the gate in `rehydrate_openbao`
  (`scripts/openbao-config.sh`) and the one in `restore`
  (`container-images/openbao-snapshot/openbao-snapshot.sh`) — compare the newest
  object's segment against the node's own seal and **refuse before
  `bao operator init` and before `snapshot restore -force`**, naming both seals.
  An object carrying no seal segment is never selected, and is named in the
  refusal rather than skipped silently.
  `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true` restores the newest object the
  node's seal *can* unwrap instead — the failback case — and is deliberately not
  the default, because skipping a newer snapshot discards writes. Snapshot image
  `v0.3.1`. The bucket is still a mixed-seal namespace: what is gone is its
  illegibility, and with it the bucket-mutation chore the failback used to
  prescribe — [step 4 of the failover
  guide]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}) is now a
  decision about whose writes to discard, taken against a listing that answers
  the question.
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
Rehydrate: `./scripts/openbao-config.sh rehydrate`, called by both management
stacks' deploy scripts. Auth mounts: `opentofu/{aws/eks,gcp/gke}/configure/openbao.tf`.
Fallback runbook: [Cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).

## References

- [ADR-0025](0025-cloud-managed-secret-stores.md), [ADR-0027](0027-primary-cloud-provider.md), [ADR-0024](0024-identity-provider-per-cloud.md), [ADR-0019](0019-cross-cloud-dns-federation.md)
- [OpenBao]({{< relref "/docs/platform/security/openbao.md" >}}), [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}), [What it costs]({{< relref "/docs/get-started/costs.md" >}})
- OpenBao docs: seal migration requires both seals reachable; Raft nodes must share a seal configuration
