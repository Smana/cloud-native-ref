---
title: Cloud Storage FUSE for LLM model weights on GCP
linkTitle: 0021 · GCS FUSE for weights
weight: 210
description: gcp-0 mounts model weights from a GCS bucket via the managed Cloud Storage FUSE CSI driver rather than hydrating a Hyperdisk ML volume, trading cold-start speed for a footprint that costs nothing between teardowns.
lastVerified: 2026-08-26
---

**Status**: Accepted
**Date**: 2026-08-26
**Deciders**: Platform Team
**Related Design**: GPU and the LLM platform on GCP (workstream 14), in the repository at
`docs/superpowers/specs/2026-08-26-gcp-llm-platform-design.md`
**Related**: [ADR-0004](0004-amazon-s3-files-for-model-weights-storage.md) — the AWS decision this
answers for the second cloud

---

## Context

[ADR-0004](0004-amazon-s3-files-for-model-weights-storage.md) chose **Amazon S3 Files** for model
weights on `aws-0`. Its four requirements were:

1. **Durable across cluster lifecycle** — clusters are rebuilt; a ~15-minute-per-model HuggingFace
   preload must not repeat.
2. **Read-fast at vLLM startup** — vLLM `mmap`s the `.safetensors` file at boot; the cold-start
   budget is 90 seconds.
3. **Shared across replicas** — KEDA scales pod count; replicas load the same file.
4. **Retained on claim deletion** — stateful storage is not auto-deleted with claims.

S3 Files satisfies all four with one resource: a POSIX file system over the bucket, so the bytes are
durable object storage *and* `mmap`-able *and* shared, with nothing else provisioned.

**GCP has no single equivalent.** The properties split across two products, and choosing between
them is a real decision rather than a port.

That matters more than it might, because `gcp-0`'s operating pattern is different from `aws-0`'s.
`aws-0` is a long-lived reference cluster. `gcp-0` is a demonstration platform built, verified and
destroyed in the same session — every GCP workstream so far has ended with `terraform destroy` and an
API-level check that nothing survives. A standing instruction governs it: nothing bills after a test.

---

## Decision Drivers

- **Nothing bills between tests.** The overriding constraint on `gcp-0`.
- **Durability across teardown**, so preload does not repeat on every rebuild.
- **Cold start**, weighted against what `gcp-0` actually is — a platform that exists for minutes.
- **Machinery cost.** Each moving part is something to build, verify and debug on a cluster that is
  destroyed before it is fully exercised.
- **A reversible decision.** If cold start proves unacceptable, changing course should not require
  redesigning anything else.

---

## Considered Options

### Option 1: Cloud Storage FUSE, bucket only

A GCS bucket holds the weights; pods mount it through GKE's managed Cloud Storage FUSE CSI driver.

**Pros**:
- Nothing is provisioned beyond the bucket, so teardown leaves storage cost alone — the same
  footprint `aws-0` leaves with its S3 bucket.
- No hydration step: the bucket *is* the source of truth, mounted directly.
- Fewest moving parts of any option.
- Managed CSI driver; a GKE addon rather than something this repo installs.

**Cons**:
- FUSE is the path ADR-0004 rated weaker for AWS — per-pod userspace gateway overhead, per-pod
  throughput limits.
- Cold start is slower than a block device, and may exceed the 90-second budget. **Unmeasured.**

### Option 2: GCS bucket plus a Hyperdisk ML volume hydrated per deploy

The bucket is the durable source; each deploy hydrates a `ReadOnlyMany` Hyperdisk ML volume from it,
and teardown destroys the volume.

**Pros**:
- Google reports Hyperdisk ML loading weights *"up to 11.9×"* faster than loading from a model
  registry.
- Persistent footprint stays a cheap bucket.
- `ReadOnlyMany` shares cleanly across replicas; `g2` — the family carrying L4 — supports
  `hyperdisk-ml`, verified.

**Cons**:
- Every deploy pays a hydration step (Job → RWO disk → convert to ROM) before the platform is
  usable, on a cluster whose whole life is measured in minutes.
- Materially more machinery to build and verify, for a benefit that only shows up under sustained
  serving load this platform never sees.

### Option 3: Hyperdisk ML persisted between tests

Hydrate once; keep the volume across rebuilds.

**Pros**:
- Fastest cold start, no repeated hydration.
- Closest in spirit to what ADR-0004 wanted: fast, shared, durable.

**Cons**:
- **A provisioned disk bills continuously between tests.** This is a direct conflict with the
  platform's standing constraint, not a trade to be weighed.
- Zonal, so it pins the platform to one zone in a way the bucket does not.

---

## Decision Outcome

**Chosen option**: "Option 1 — Cloud Storage FUSE, bucket only".

**Rationale**: it is the only option whose resting state costs nothing but storage, which is the
constraint that governs `gcp-0`. Options 2 and 3 buy cold-start speed, and cold-start speed is worth
less here than it is on `aws-0` — the 90-second budget is a serving SLO for a platform that stays up,
and `gcp-0` is destroyed the same day it is built. Option 3 additionally bills while idle, which is
disqualifying rather than merely expensive.

**The cost is real and is not argued away.** ADR-0004 rejected FUSE for AWS on per-pod overhead and
throughput limits, and that reasoning does not stop being true on GCP. What changes is which
requirement binds. This ADR accepts a slower cold start on a demonstration platform in exchange for
a footprint that matches how the platform is actually used.

**This decision is reversible by design.** The bucket is the source of truth in every option. If
cold start is measured and found unacceptable, Option 2 adds a hydration step and a volume on top of
the same bucket — no manifest outside the mount changes, and this ADR is superseded rather than
unpicked.

---

## Consequences

### Positive

- Teardown leaves a bucket and nothing else, matching every other GCP workstream's end state.
- Fewest moving parts, on the cloud where the platform is least exercised.
- The managed CSI driver is Google's to maintain.

### Negative

- Cold start is slower than `aws-0`'s, by an amount nobody has measured. **No claim is made about
  whether it meets the 90-second budget** — asserting that without measuring is precisely the habit
  this programme has been correcting.
- The two clouds now load weights differently, so a change to the weights path has to be reasoned
  about twice.

### Neutral

- `aws-0` is untouched. ADR-0004 stands.

---

## Implementation Notes

The bucket is named `<project_id>-ogenki-llm-models`, **not** `<region>-ogenki-llm-models` as on AWS.
The Crossplane principal's storage role is conditioned on
`resource.name.startsWith('projects/_/buckets/<project_id>-ogenki-')`, so a region-prefixed name is
refused at create with a 403 naming `storage.buckets.create` — a permission the custom role *does*
grant, which is why the error points nowhere near the condition that actually rejected it. Measured
on a live cluster during workstream 9.

The Cloud Storage FUSE CSI driver is a GKE addon and must be enabled on the cluster. Confirm the
module variable against the vendored `terraform-google-modules/kubernetes-engine` source before
writing it; a wrong name produces mounts that hang with no obvious cause.

---

## References

- [ADR-0004](0004-amazon-s3-files-for-model-weights-storage.md) — the AWS decision, including the
  option table that rated FUSE a rollback target rather than a first choice
- [Accelerate AI/ML data loading with Hyperdisk ML](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk-ml)
  — `ReadOnlyMany`, hydration, the 11.9× figure, and the zonal constraint
- [Optimize AI and ML workloads with Cloud Storage FUSE](https://docs.cloud.google.com/architecture/optimize-ai-ml-workloads-cloud-storage-fuse)
- [GPU machines in the accelerator-optimized family](https://docs.cloud.google.com/compute/docs/accelerator-optimized-machines)
  — `g2` supports `hyperdisk-ml`, which is why Option 2 was a genuine candidate rather than
  unavailable
