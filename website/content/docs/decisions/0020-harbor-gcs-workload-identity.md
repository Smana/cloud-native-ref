---
title: Harbor on GCS — native driver with Workload Identity, not S3-compatible HMAC
linkTitle: 0020 · Harbor GCS Workload Identity
weight: 200
description: Harbor's registry on gcp-0 uses the chart's native gcs storage driver with useWorkloadIdentity, rather than pointing the existing S3 driver at Google's S3-compatible endpoint with HMAC keys, so that no static credential is introduced on the GCP side.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-26
**Deciders**: Platform Team
**Related Design**: Object-storage call sites on GCP (workstream 9), in the repository at
`docs/superpowers/specs/2026-08-26-gcp-object-storage-design.md`

---

## Context

Harbor's registry stores image layers in object storage. On `aws-0` it uses the `s3` driver with an
IAM **user** and static access keys, injected as `REGISTRY_STORAGE_S3_ACCESSKEY` /
`REGISTRY_STORAGE_S3_SECRETKEY`. That is not the platform's usual pattern — everything else on
`aws-0` uses EKS Pod Identity ([ADR-0002](0002-eks-pod-identity-over-irsa.md)) — and the reason is
[goharbor/harbor#18686](https://github.com/goharbor/harbor/pull/18686): the registry's S3 driver
does not pick up Pod Identity credentials. The static key is a workaround for an upstream gap.

Bringing Harbor to `gcp-0` raised the question of whether that workaround has to travel with it.

The initial framing of this decision assumed it did — that Harbor was "stuck with static
credentials either way", making Google's S3-compatible endpoint the obvious choice since it would
reuse the existing driver, the existing env vars and the existing shape. That assumption was wrong,
and checking it changed the outcome. goharbor#18686 is specific to the **S3** driver's credential
chain on AWS. It says nothing about GCP, and `harbor-helm`'s `values.yaml` carries a first-class
key for exactly this:

```yaml
  gcs:
    bucket: bucketname
    encodedkey: base64-encoded-json-key-file
    existingSecret: ""
    useWorkloadIdentity: false
```

---

## Decision Drivers

- **No static credentials** where the platform can avoid them — a standing rule in the
  [platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}}).
- **Least privilege on storage.** A grant for Harbor must not reach OpenBao's snapshot bucket or
  CNPG's backup bucket.
- **Symmetry is worth something, but not everything.** One shared code path across clouds is easier
  to reason about — unless it imports a weakness that only one cloud actually requires.
- **Upstream support.** A first-class chart key is a maintained path; an interoperability shim is a
  compatibility surface that can regress without notice.

---

## Considered Options

### Option 1: Native `gcs` driver with `useWorkloadIdentity: true`

Harbor on `gcp-0` uses the chart's GCS driver and authenticates as its Kubernetes ServiceAccount
through GKE Workload Identity. Access is granted by a `GCPWorkloadIdentity` claim using
`spec.bucketRoles`, which binds a role on a **single** bucket.

**Pros**:
- No credential exists to leak, rotate, or commit. Nothing is mounted.
- Bucket-scoped by construction — `bucketRoles`, not a project-level `roles/storage.*`.
- A supported, documented chart key rather than a compatibility mode.
- The driver talks to the GCS JSON API natively, so multipart upload behaviour is Google's own.

**Cons**:
- `aws-0` and `gcp-0` no longer share one storage driver, so the Helm values diverge per cloud.
- Cannot be verified without Harbor running on `gcp-0`, which needs `SQLInstance` and `KVStore` on
  GCP — out of workstream 9's scope. The chart key's existence is confirmed; its runtime behaviour
  is assumed.

### Option 2: S3-compatible endpoint with HMAC keys

Keep `imageChartStorage.type: s3` on both clouds; on GCP set
`regionendpoint: https://storage.googleapis.com`, `v4auth: true`, and supply an HMAC key pair
through the same two env vars.

**Pros**:
- One driver, one manifest shape, one mental model. The GCP overlay would be three lines.
- Reuses a code path already exercised in production on `aws-0`.
- HMAC keys can be scoped to a service account, so the blast radius is not unbounded.

**Cons**:
- **Introduces a static credential on a cloud that does not require one.** This is the deciding
  cost: it would be a self-inflicted version of the AWS workaround.
- Adds a secret to create, store, rotate and audit, plus the External Secrets wiring to deliver it.
- Google's S3 interoperability is a compatibility surface, not the primary API; registry drivers
  lean on multipart upload semantics, and divergences there surface as corrupt large layers rather
  than as clean errors.

### Option 3: Native `gcs` driver with a service-account JSON key

Use the GCS driver, but authenticate with `encodedkey` / a secret containing `GCS_KEY_DATA`.

**Pros**:
- Native driver, so the multipart concerns of Option 2 do not apply.
- Works identically outside GKE, which would matter if Harbor ever ran off-cluster.

**Cons**:
- A service-account JSON key is a **broader and longer-lived** credential than an HMAC pair — it is
  the identity itself rather than a bucket-scoped signing secret.
- Strictly worse than Option 1 in the environment we actually run: on GKE, Workload Identity is
  available and this discards it.

---

## Decision Outcome

**Chosen option**: "Option 1 — native `gcs` driver with `useWorkloadIdentity: true`".

**Rationale**: It is the only option that adds no credential. The symmetry argument for Option 2 is
real but inverted on inspection: it would make the two clouds look alike by giving GCP a weakness
that only AWS is forced into, and the thing being shared is a workaround for an upstream bug. The
per-cloud divergence in Helm values is confined to one block and is honest about why it exists.

Option 3 was rejected because it trades Workload Identity for a stronger, longer-lived credential
while gaining only portability the platform does not need.

The asymmetry stands on the record: `aws-0` keeps its IAM user because goharbor#18686 genuinely
forces it. If that issue is resolved upstream, the AWS side should follow ADR-0002 and move to Pod
Identity, at which point both clouds are keyless and this ADR's tension disappears.

---

## Consequences

### Positive

- Workstream 9 introduces **zero new static credentials** across all three of its call sites.
- Harbor's GCS access is bucket-scoped, so it cannot read OpenBao snapshots or CNPG backups even by
  accident.
- The `useWorkloadIdentity` path is upstream-maintained.

### Negative

- `imageChartStorage` diverges per cloud, so the two overlays must be read together when the
  Harbor chart is upgraded. Mitigation: the base file carries a comment pointing at this ADR.
- Runtime behaviour is unverified until Harbor runs on `gcp-0`. Mitigation: stated as an assumption
  in the design rather than claimed as tested, and Option 2 remains the documented fallback if the
  driver misbehaves.
  **Update (2026-08-30):** Harbor has since run on `gcp-0` (2026-08-28, per
  [ADR-0028](0028-harbor-oidc-config-overwrite-json.md), which describes that boot rather than the
  GCS driver specifically). The GCS driver's runtime behaviour has not been separately re-verified
  in this record.

### Neutral

- `aws-0` is untouched by this decision. Its rendered output must stay byte-identical.

---

## Implementation Notes

Access is granted through the `GCPWorkloadIdentity` composition's `spec.bucketRoles`, verified
present in `crossplane-configuration-gcp` as of `v0.3.1` (pin since bumped to `v0.4.6`). The item
shape is `{bucket, role}` — `role` is **singular**.

The `principal://` member string is built by the composition and must never be reconstructed in a
manifest: `projects/` takes the project **number** while `workloadIdentityPools/` takes the project
**ID**, and reversing them yields a binding the API accepts and which silently never matches. See
the trap comment in `opentofu/gcp/gke/init/iam.tf`.

---

## References

- [goharbor/harbor#18686](https://github.com/goharbor/harbor/pull/18686) — the S3 driver's Pod
  Identity gap that forces the AWS-side static key
- [Cloud Storage interoperability](https://docs.cloud.google.com/storage/docs/interoperability) —
  Google's S3-compatible XML API and HMAC keys, the basis of the rejected Option 2
- [ADR-0002](0002-eks-pod-identity-over-irsa.md) — the credential pattern this restores on GCP
- [ADR-0007](0007-cloud-abstraction-boundaries.md) — where per-cloud divergence is allowed to live
