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
./scripts/cnpg-promote-seed.sh --cluster xplane-zitadel --namespace security \
  --cloud gcp --bucket <project>-ogenki-cnpg-backups --apply
```

It discovers the live prefix from the cluster's own `serverName` rather than
guessing it from the claim name, takes a one-shot Backup, forces the final WAL
segment out before copying — the step that made `zitadel-20260829-2`
unrestorable when it was done by hand — and verifies the result actually holds
a restorable base backup rather than counting objects.

On AWS the same command takes `--cloud aws --bucket <region>-ogenki-cnpg-backups`.

Then point the claim at it — `security/gcp-0/zitadel/kustomization.yaml`:

```yaml
- op: replace
  path: /spec/objectStoreRecovery/path
  value: zitadel-20260828
```

## 2. Why the destination is always empty

CloudNativePG refuses to start a **restored** cluster whose destination WAL
archive is non-empty — a restore opens a new timeline that would collide with the
WALs already there:

```
barman-cloud-check-wal-archive: WAL archive check failed for server
xplane-zitadel-cnpg-cluster: Expected empty archive
```

Since [#1963](https://github.com/Smana/cloud-native-ref/issues/1963) this can no
longer happen: each cluster generation writes to its own prefix, keyed by the
XR uid, rather than reusing the bare `xplane-<name>-cnpg-cluster/` name:

```
s3://<bucket>/
  xplane-zitadel-cnpg-cluster-a1b2c3d4/   generation N
  xplane-zitadel-cnpg-cluster-9f8e7d6c/   generation N+1, empty on create
  zitadel-20260902/                       frozen seed, read-only
```

A new generation's destination is empty because it never existed — there is
nothing to clear, on either cloud, for a cluster that restores or one that
bootstraps empty. Recovery is unaffected by any of this: it reads
`spec.objectStoreRecovery.path` explicitly and never touches a live archive.

{{< callout type="info" >}}
`scripts/cnpg-prepare-restore.sh` still exists as an escape hatch for the cases
that still collide: a cluster pinned to an explicit `serverName`, an archive
left behind by a pre-#1963 generation, or a deliberate reuse of a prefix. It
refuses to clear a live archive unless the named seed actually holds a base
backup — read the script's header for the guard and the two failure modes
("could not check" vs "empty") it distinguishes.
{{< /callout >}}

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
migration, significant user growth. Re-run `scripts/cnpg-promote-seed.sh` (it
defaults the seed name to `<cluster>-$(date +%Y%m%d)` if `--seed` is omitted)
and update `path`. The old prefix costs a few tens of megabytes; keep it until
the new one has been restored from at least once.

## Related

- [Teardown]({{< relref "/docs/get-started/gcp/teardown.md" >}}) — the backup
  bucket must **survive** a teardown, or the next build has nothing to restore from
- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) —
  why each cloud runs its own ZITADEL, and why that makes restore matter
