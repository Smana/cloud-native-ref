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

## `s3Bucket` — object storage with Pod Identity

Creates an S3 bucket and an EKS Pod Identity so your pods get scoped AWS
credentials automatically — no static keys. The bucket name is derived, not
chosen: `<region>-ogenki-<app-name>`
(`apis/app/kcl/main.k:1080` in `Smana/crossplane-configuration`):

```yaml
  s3Bucket:
    enabled: true
    region: eu-west-3
    permissions: readwrite    # readwrite | readonly | custom
    versioning: true
    retentionDays: 90
```

With `permissions: custom`, supply your own IAM policy JSON in
`customPolicy`. Every other permission level renders a scoped inline IAM
policy against that one bucket's ARN via a nested `EPI` claim
(`apis/app/kcl/main.k:1131-1150`) — see
[ADR-0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}})
for why Pod Identity over IRSA, and
[EPI]({{< relref "/docs/reference/glossary.md" >}}) in the glossary for what
that nested claim renders.

## Together: an app that uses all three

Toggling `sqlInstance`, `kvStore`, and `s3Bucket` on the same claim wires
`DATABASE_URL`, `REDIS_URL`, the S3 bucket, and its Pod Identity together
automatically — you never type an `xplane-*` name or a `secretKeyRef`
yourself. The [App Wizard]({{< relref "/docs/platform/developer-platform/app-wizard.md" >}})
page walks a full worked example (Outline, a self-hosted wiki) that does
exactly this.
