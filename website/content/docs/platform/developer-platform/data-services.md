---
title: Data services
weight: 20
description: PostgreSQL, Valkey, and S3 — provisioned inline with an App claim and wired automatically, no xplane-* name or secretKeyRef to write by hand.
lastVerified: 2026-08-20
---

Three infrastructure blocks on an `App` claim are orthogonal to
`spec.type` — a web app, worker, or cron can request any of them. Each is
rendered by the `App` composition as a nested resource, not a separate claim
you write yourself.

## `sqlInstance` — PostgreSQL

Provisions a highly-available PostgreSQL cluster on
[CloudNativePG](https://cloudnative-pg.io/) — the App composition renders a
nested `SQLInstance` claim, which in turn renders the `postgresql.cnpg.io/v1`
`Cluster` (`apis/sqlinstance/kcl/main.k:236-237` in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)):

```yaml
  sqlInstance:
    enabled: true
    size: small               # small | medium | large
    storageSize: 20Gi
    instances: 2               # replicas for HA
    databases:
      - name: myapp
        owner: myapp-app
    roles:
      - name: myapp-app
        superuser: false
    backup:
      schedule: "0 2 * * *"    # if set, bucketName is required
      bucketName: myapp-db-backups
      retentionPolicy: "30d"
```

A backup `schedule` requires `backup.bucketName` — the API server enforces
this. Schema migrations are declared via `atlasSchema` (a Git `url`, `ref`,
and `path` to migration files); the composition renders a
`GitRepository` + `Kustomization` + `AtlasMigration` pipeline per database
so Atlas Operator applies them declaratively
(`apis/sqlinstance/kcl/main.k:477-539`). See `.claude/rules/database-migrations.md`
for the migration-repository layout and Git-ref-to-tag/branch rules if you
use it.

Your workload's `DATABASE_URL` is wired for you automatically — the App
composition sets it to the CloudNativePG connection secret for the first
declared database, unless you set `DATABASE_URL` yourself
(`apis/app/kcl/main.k:403-419` in `Smana/crossplane-configuration`).

## `kvStore` — Valkey

An in-cluster [Valkey](https://valkey.io/) key-value store for caching,
sessions, or queues, delivered as a nested `KVStore` composition backed by
the official [valkey-helm](https://github.com/valkey-io/valkey-helm) chart
(SPEC-012). Cache semantics: standalone and ephemeral by default — a
restarted pod means a refilled cache, not lost data.

```yaml
  kvStore:
    enabled: true
    size: small               # small | medium | large
```

Your workload automatically receives `REDIS_URL=redis://<managed-name>-valkey:6379`
unless you set `REDIS_URL` yourself
(`apis/app/kcl/main.k:420` in `Smana/crossplane-configuration`).

{{< callout type="warning" >}}
`kvStore.type` (`valkey`\|`redis`) still exists on the schema but is
**ignored** — the backend is Valkey-only. It's kept for API compatibility
with claims written before the migration off the legacy Bitnami chart.
{{< /callout >}}

## `objectStore` — object storage with workload identity

Creates a bucket and a scoped workload identity so your pods get credentials
automatically — no static keys, on either cloud. **The same claim renders S3 on
`aws-0` and GCS on `gcp-0`**; the composition picks the implementation from the
cluster's own EnvironmentConfig.

The bucket name is derived, not chosen — `<scope>-ogenki-<app-name>`, where the
scope is the AWS region or the GCP project ID. The project ID is used on GCP
because GCS bucket names are globally unique across all of Google Cloud, unlike
S3 names.

```yaml
  objectStore:
    enabled: true
    permissions: readwrite    # readwrite | readonly | custom
    versioning: true
    retentionDays: 90
```

Note there is no `region`. The claim does not say where the bucket lands — that
comes from the cluster — which is what lets the same manifest deploy to either
cloud. Override it only if you must, via `aws.region` or `gcp.location`.

| | `aws-0` | `gcp-0` |
|---|---|---|
| Bucket | S3 `Bucket` + `BucketVersioning` | GCS `Bucket`, versioning inline |
| Identity | `EPI` (EKS Pod Identity) | `GCPWorkloadIdentity` |
| Grant | inline IAM policy scoped to the bucket ARN | `roles/storage.objectAdmin` on that one bucket |

Both grants are **bucket-scoped**, not project- or account-wide. On GCP that
matters more than it sounds: a project-level `roles/storage.*` would reach every
bucket in the project, including OpenBao's snapshots and database backups.

{{< callout type="warning" >}}
**`permissions: custom` is AWS-only.** Supply your IAM policy JSON in
`aws.customPolicy` — the XRD rejects `custom` without it. IAM JSON has no GCP
equivalent, so on GCP the composition degrades `custom` to read-only rather than
silently granting write.
{{< /callout >}}

{{< callout type="warning" >}}
**`retentionDays` currently takes effect on GCP only.** The example above sets
`retentionDays: 90` and it means two different things per cloud today: on `gcp-0`
it renders a GCS lifecycle rule that deletes objects past that age; on `aws-0` it
is accepted and stored but does nothing — no S3 lifecycle configuration renders
yet, so uploads never expire there. Don't rely on it for AWS data retention until
an S3 implementation lands.
{{< /callout >}}

See [ADR-0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}})
for why Pod Identity over IRSA on AWS,
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
for why the cloud-specific knobs live in `aws {}` / `gcp {}` blocks, and
[EPI]({{< relref "/docs/reference/glossary.md" >}}) in the glossary for what the
nested AWS identity claim renders.

## Together: an app that uses all three

Toggling `sqlInstance`, `kvStore`, and `objectStore` on the same claim wires
`DATABASE_URL`, `REDIS_URL`, the bucket, and its workload identity together
automatically — you never type an `xplane-*` name or a `secretKeyRef`
yourself. The [App Wizard]({{< relref "/docs/platform/developer-platform/app-wizard.md" >}})
page walks a full worked example (Outline, a self-hosted wiki) that does
exactly this.
