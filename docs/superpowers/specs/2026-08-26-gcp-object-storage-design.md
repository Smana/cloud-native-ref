# Object-storage call sites on GCP — workstream 9

**Date:** 2026-08-26
**Status:** approved, not yet implemented
**Workstream:** 9 of the [GCP support programme](2026-08-18-gcp-support-design.md)
**ADR:** [ADR-0020](../../../website/content/docs/decisions/0020-harbor-gcs-workload-identity.md)

## Problem

Three workloads write to object storage, and all three name AWS in their manifests:

| Call site | File | AWS shape today |
|---|---|---|
| Harbor registry | `tooling/base/harbor/{helmrelease-harbor,s3-bucket,iam-user}.yaml` | `imageChartStorage.type: s3`, a raw `s3.aws.m.upbound.io` Bucket, and an IAM **user with static keys** |
| OpenBao snapshots | `security/base/openbao-snapshot/`, `scripts/openbao-snapshot.sh`, `security/base/epis/openbao-snapshot.yaml` | `aws s3 cp` / `aws s3api` / `aws secretsmanager` inside `smana/openbao-snapshot:v0.1.0`, identity via EPI |
| CNPG backups | `security/base/zitadel/sqlinstance.yaml` | `bucketName: eu-west-3-ogenki-cnpg-backups`, hardcoded |

None of the three has a `gcp-0` consumer yet. Like workstream 13, this is **preparatory**: the base
manifests become portable now, before Harbor, zitadel and the LLM platform reach GCP, rather than
after they break there.

## What is already solved, and verified

Checked against the pinned artifacts rather than against documents describing them:

- **`crossplane-configuration-{aws,gcp}` are both at `v0.3.1`.** The GCP side is not lagging.
- **`GCPWorkloadIdentity` already has `spec.bucketRoles`** — confirmed by reading
  `apis/gcpworkloadidentity/definition.yaml` at tag `v0.3.1`, not by reading workstream 8's plan.
  Item shape is `{bucket, role}` — **`role` singular**, and a CEL rule requires at least one of
  `roles` or `bucketRoles`. Its own description names this workstream's call sites:

  > a project-level `roles/storage.*` grant reaches every bucket in the project, including OpenBao
  > snapshots and CNPG backups, which is almost never what a workload needs.

  So the bucket-scoped grant this workstream needs was built in anticipation of it. Nothing has to
  change in `Smana/crossplane-configuration`.
- **`buckets.storage.gcp.m.upbound.io` and `bucketiammembers.storage.gcp.m.upbound.io` are both
  activated** in `infrastructure/base/crossplane/providers-gcp/activation-policy.yaml`.
- **The `harbor-helm` chart has a native `gcs` driver with `useWorkloadIdentity`** — read from
  `values.yaml` upstream:

  ```yaml
  gcs:
    bucket: bucketname
    encodedkey: base64-encoded-json-key-file
    existingSecret: ""
    useWorkloadIdentity: false
  ```

## Design

### Authentication — no new static credentials

goharbor#18686 blocks EKS Pod Identity for the **S3** driver on AWS, which is why `aws-0` keeps an
IAM user. It says nothing about GCP, and the chart's `gcs` driver takes Workload Identity directly.
So every GCP call site here is keyless:

| Call site | `aws-0` | `gcp-0` |
|---|---|---|
| Harbor | IAM user + static keys (forced by goharbor#18686) | `GCPWorkloadIdentity` + `useWorkloadIdentity: true` |
| openbao-snapshot | `EPI` | `GCPWorkloadIdentity` |
| CNPG | `EPI` via the composition | `GCPWorkloadIdentity` via the composition |

Every GCS grant is `bucketRoles`, never `roles`. A project-level `roles/storage.objectAdmin` would
let Harbor read OpenBao's snapshots.

The `principal://` string is **never reconstructed** in this repo. `opentofu/gcp/gke/init/iam.tf`
documents why: `projects/` takes the project **NUMBER** while `workloadIdentityPools/` takes the
project **ID**, and reversing them produces a binding the API accepts and which silently never
matches. The composition builds it; claims pass `serviceAccount.name` and let it.

### Bucket naming — the existing convention already ports

`${region}-ogenki-<name>` needs no change. Both clusters define `region`, and
`europe-west4-ogenki-harbor` is a valid GCS bucket name. CNPG's hardcoded
`eu-west-3-ogenki-cnpg-backups` becomes `${region}-ogenki-cnpg-backups`, which renders
**byte-identical on `aws-0`**.

`objectStoreRecovery.path: zitadel-20260719` stays AWS-only: it points at a frozen snapshot prefix
that exists in one bucket on one cloud. A future `gcp-0` zitadel starts with no recovery source.

### The snapshot script and its image

`scripts/openbao-snapshot.sh` calls `aws` in four places — `s3 cp` (save), `s3api list-objects-v2`
and `s3 cp` (restore), and `secretsmanager get-secret-value` (recovery keys). A `CLOUD=aws|gcp`
switch selects `aws` or `gcloud`/`gsutil` per call. One image carries both CLIs.

rclone was rejected because the secret-manager call has to branch regardless, so a storage-only
abstraction solves three of four sites and adds a dependency for it.

The image moves in-repo as `container-images/openbao-snapshot/{Dockerfile,build.sh,README.md}`,
following the `pev2` precedent, and publishes to `ghcr.io/smana/openbao-snapshot` via the existing
`.github/workflows/build-container-images.yml`. It is currently `smana/openbao-snapshot:v0.1.0` on
Docker Hub with no Dockerfile in any repo we control.

> That workflow has a known scar: a `changed-files` JSON-escaping bug once emptied the build matrix
> and **still reported success**, so `ghcr.io/smana/app-wizard` was never published despite green
> runs on `main`. Confirm the image actually exists in the registry before wiring the CronJob to it.

## Verification — what can and cannot be proven

**Provable end to end, and will be:** the snapshot path. Workstream 11 already put OpenBao on GCP
(`opentofu/gcp/openbao/{cluster,management}`, PRs #1827/#1830/#1833), so `gcp-0` + OpenBao gets
deployed, a snapshot is taken, and it is confirmed in the GCS bucket and restored from. Then torn
down — nothing is left running.

**Not provable in this workstream, and will not be claimed:** Harbor against GCS. Verifying it
needs Harbor running on `gcp-0`, which needs `SQLInstance` and `KVStore` on GCP — a separate
workstream. The chart key is confirmed to exist; that the registry authenticates to GCS through it
at runtime is an assumption stated as one. Same for CNPG, which has no `gcp-0` consumer at all.

This is deliberate. Workstream 13 shipped with every gate green on a StorageClass name that did not
exist, because nothing rendered the GCP shape. Naming the unproven half is the correction.

## Out of scope

- `Smana/crossplane-configuration` — `v0.3.1` already provides everything needed.
- Deploying Harbor, zitadel or CNPG to `gcp-0`.
- `aws-0` behaviour. Every AWS-side change here must render byte-identical.
