---
title: Restore a database from object storage
weight: 40
description: How a CloudNativePG cluster bootstraps from a frozen backup, the check that will refuse it, and how to verify the restore actually worked.
lastVerified: 2026-08-29
---

A `SQLInstance` claim can bootstrap a brand-new database from a backup in object
storage instead of starting empty. `security/gcp-0/zitadel` does exactly that, and
this page is how it was proven to work.

{{< callout type="info" >}}
Performed end to end on `gcp-0` on 2026-08-29 — the first restore ever run in this
repository, on either cloud. It works, and it needs one step that is not obvious.
{{< /callout >}}

## Why bother

A ZITADEL that bootstraps **empty** loses, on every rebuild, everything the
setup scripts cannot recreate:

- the Google IdP's **user links**, and
- **any human user at all** — which exists only after a first interactive login,
  and therefore cannot be seeded by a script that runs at bootstrap.

`scripts/zitadel-oidc-clients.sh` and `scripts/zitadel-idp.sh` can rebuild the
provider, the clients, the project, its roles and the login policy. They cannot
rebuild the fact that a person logged in once. Restoring is the difference
between *the platform comes back* and *the platform is rebuilt and everyone logs
in again to re-earn their grants*.

## 1. Freeze a seed

Recovery points at a **frozen, dated prefix**, never at the live cluster's own
archive — a live prefix keeps changing under you, and the whole point is a known
state you can return to.

```bash
# a) one-shot backup, so the seed contains the current configuration
kubectl apply -n security -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: zitadel-restore-seed
  namespace: security
spec:
  cluster:
    name: xplane-zitadel-cnpg-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl get backup -n security zitadel-restore-seed -w   # wait for phase=completed

# b) copy the cluster prefix to a dated one
gcloud storage cp --recursive \
  gs://<project>-ogenki-cnpg-backups/xplane-zitadel-cnpg-cluster/* \
  gs://<project>-ogenki-cnpg-backups/zitadel-$(date +%Y%m%d)/
```

On AWS the same two steps use `aws s3 cp --recursive` against
`s3://<region>-ogenki-cnpg-backups/`.

Then point the claim at it — `security/gcp-0/zitadel/kustomization.yaml`:

```yaml
- op: replace
  path: /spec/objectStoreRecovery/path
  value: zitadel-20260828
```

## 2. The check that will refuse the restore

{{< callout type="warning" >}}
**Clear the live archive first, or the restore will not start.**
{{< /callout >}}

CloudNativePG refuses to start a restored cluster whose **destination** WAL
archive is non-empty — a restore opens a new timeline that would collide with the
WALs already there:

```
barman-cloud-check-wal-archive: WAL archive check failed for server
xplane-zitadel-cnpg-cluster: Expected empty archive
```

This is not an edge case. The backup bucket **outlives the cluster on purpose**
(`infrastructure/gcp-0/cloudnative-pg/gcs-bucket.yaml`: *"backups outlive any
individual cluster"*), so on every rebuild the destination still holds the
previous cluster's archive and the bootstrap refuses.

`scripts/cnpg-prepare-restore.sh` does this with the guard that makes it safe —
it refuses unless the dated seed actually holds a base backup, so the live
archive is never cleared when there would be nothing to restore from:

```bash
./scripts/cnpg-prepare-restore.sh --cloud gcp --project <project> \
  --bucket <project>-ogenki-cnpg-backups \
  --cluster xplane-zitadel-cnpg-cluster --seed zitadel-20260828      # dry run
# ... then --apply
```

It distinguishes *could not check* from *empty*: if the listing fails — a stale
credential is the usual cause — it refuses and says so, rather than reporting an
absent seed and inviting you to proceed.

On `aws-0` this step has always been done by hand before a rebuild, which is why
restores work there; the script is the same operation with the check attached:

```bash
./scripts/cnpg-prepare-restore.sh --cloud aws --region <region> \
  --bucket <region>-ogenki-cnpg-backups \
  --cluster xplane-zitadel-cnpg-cluster --seed zitadel-20260719
```

The durable fix is a per-generation `serverName` in the `SQLInstance`
Composition, which would remove the step on both clouds. Until then it is a
normal part of restoring — on `aws-0` it has always been done, just never
written down.

## 3. Force the bootstrap

`bootstrap` is **immutable on an existing CloudNativePG cluster**. An existing
database will never re-bootstrap, no matter what the claim says, so recovery only
happens on creation:

```bash
kubectl delete cluster.postgresql.cnpg.io -n security xplane-zitadel-cnpg-cluster
kubectl delete pvc -n security xplane-zitadel-cnpg-cluster-1
```

Delete the **PVC as well**. A surviving volume means CloudNativePG reuses it and
skips the restore entirely — which looks like success and is not.

Crossplane then recreates the cluster, and this is what proves the wiring:

```bash
kubectl get cluster.postgresql.cnpg.io -n security \
  xplane-zitadel-cnpg-cluster -o jsonpath='{.spec.bootstrap}'
# {"recovery":{"database":"app","owner":"app","source":"zitadel-20260828"}}
```

## 4. Verify against a baseline, not against a feeling

A cluster reporting *"in healthy state"* only means Postgres started. Capture the
application's own state **before** deleting anything, and compare after:

```bash
# before
./scripts/zitadel-oidc-clients.sh ...   # or the ZITADEL API directly
```

The `gcp-0` run compared users, OIDC apps, project roles, user grants and
identity providers. All five matched exactly:

| | before | after |
|---|---|---|
| users | 3 | 3 |
| OIDC apps | grafana, headlamp, flux-ui, headlamp-proxy, harbor | identical |
| project roles | admin, backend, frontend, data | identical |
| grants | one admin grant | identical |
| identity providers | Google Workspace | identical |

## Rotating the seed

Refresh it when the database changes meaningfully — new OAuth apps, a schema
migration, significant user growth. Repeat step 1 with a new date and update
`path`. The old prefix costs a few tens of megabytes; keep it until the new one
has been restored from at least once.

## Related

- [Teardown]({{< relref "/docs/get-started/gcp/teardown.md" >}}) — the backup
  bucket must **survive** a teardown, or the next build has nothing to restore from
- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) —
  why each cloud runs its own ZITADEL, and why that makes restore matter
