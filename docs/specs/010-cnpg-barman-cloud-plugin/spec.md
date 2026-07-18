# Spec: Migrate SQLInstance backups to the Barman Cloud CNPG-I plugin

**ID**: SPEC-010
**Issue**: [#1635](https://github.com/Smana/cloud-native-ref/issues/1635)
**Status**: draft
**Type**: composition
**Created**: 2026-07-18
**Last updated**: 2026-07-18

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Migrate the `SQLInstance` composition's PostgreSQL backups from the **deprecated in-tree `barmanObjectStore`** to the **Barman Cloud CNPG-I plugin** (`ObjectStore` CR + `Cluster.spec.plugins` reference), preserving the existing IAM-role (EKS Pod Identity) credential path and S3 destination. This unblocks the CloudNativePG operator `1.31.0` upgrade, which removes in-tree Barman Cloud entirely.

---

## Problem

In-tree Barman Cloud backup (`spec.backup.barmanObjectStore`) is **deprecated since CNPG 1.26 and removed in operator 1.31.0**. The `SQLInstance` composition renders in-tree `barmanObjectStore` at **two sites** — the backup config (`kcl/cloudnativepg/main.k:273-288`) and the PITR recovery `externalClusters` (`main.k:325-339`). The cluster currently runs operator **1.30.0** (chart `0.29.0`, CRDs pinned to gitrepo `v1.30.0`), so backups still work today — but the moment we bump past 1.30.x, both **scheduled backups + WAL archiving** and **point-in-time recovery** break.

We must migrate the composition to the plugin model *before* the operator bump, without changing the user-facing backup API or the S3 credential model (IAM role via Pod Identity, `inheritFromIAMRole`).

---

## User Stories

### US-1: Backups keep working after the operator upgrade (Priority: P1)

As a **platform user declaring a `SQLInstance` with backups**, I want daily backups and WAL archiving to keep working after the CNPG operator upgrade, so that my database stays recoverable.

**Acceptance Scenarios**:
1. **Given** a `SQLInstance` claim with `spec.backup.schedule` set, **When** the composition renders on the plugin-enabled operator, **Then** a `ScheduledBackup` with `method: plugin` produces a completed `Backup` object writing to S3.
2. **Given** the same claim, **When** continuous archiving runs, **Then** WAL segments are archived to S3 via the plugin (no in-tree `barmanObjectStore` in the rendered `Cluster`).

### US-2: PITR recovery keeps working (Priority: P1)

As a **platform operator**, I want point-in-time recovery (`spec.objectStoreRecovery`) to keep working via the plugin, so that restore paths don't regress.

**Acceptance Scenarios**:
1. **Given** a `SQLInstance` claim with `spec.objectStoreRecovery` set, **When** the composition renders, **Then** the `Cluster` bootstraps recovery from an `ObjectStore` (plugin `externalClusters` ref), not an in-tree `barmanObjectStore`.

### US-3: Composition free of deprecated APIs before 1.31.0 (Priority: P2)

As a **platform maintainer**, I want the composition free of deprecated Barman APIs before operator 1.31.0, so the CNPG version bump is unblocked.

**Acceptance Scenarios**:
1. **Given** a rendered `SQLInstance`, **When** I grep the output, **Then** no `barmanObjectStore` key appears in any `Cluster` or `externalClusters` block.

---

## Requirements

### Functional

- **FR-001**: The composition MUST render one barman-cloud `ObjectStore` CR per `SQLInstance` with backups enabled, carrying the S3 `destinationPath`, `retentionPolicy`, and `wal`/`data` compression currently on `barmanObjectStore` (`main.k:273-288`).
- **FR-002**: The `Cluster` MUST reference the plugin via `spec.plugins: [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true, parameters: {barmanObjectName: <ObjectStore name>}}]`.
- **FR-003**: `ScheduledBackup` MUST set `spec.method: plugin` and the plugin reference (exact field — `pluginConfiguration.name` — per the targeted plugin CRD), replacing the default in-tree method (`main.k:649-670`).
- **FR-004**: The recovery path (`externalClusters[].barmanObjectStore`, `main.k:325-339`, driven by `spec.objectStoreRecovery`) MUST migrate to the plugin recovery model (`ObjectStore` + `externalClusters` plugin ref).
- **FR-005**: Retention MUST move from `Cluster.spec.backup.retentionPolicy` (`main.k:287`) to `ObjectStore.spec.retentionPolicy`.
- **FR-006**: **By default**, S3 credentials MUST use credential-less IAM (EKS Pod Identity) — the `ObjectStore` omits explicit `s3Credentials` and the plugin sidecar inherits ambient credentials from the existing `PodIdentityAssociation` (SA `<name>-cnpg-cluster`, `main.k:744-761`) — with **no new Kubernetes Secret**. A claim MAY opt into access-key mode (keys sourced from OpenBao via `ExternalSecret`, referenced in `ObjectStore.s3Credentials`). See CL-4. *(Default path conditional on FR-007 verifying the `ObjectStore` accepts an omitted `s3Credentials` block; the IRSA `eks.amazonaws.com/role-arn` annotation MUST NOT be used — Pod Identity supplies ambient creds.)*
- **FR-007**: The barman-cloud plugin (controller `Deployment` + `ObjectStore` CRD) MUST be installed cluster-wide (greenfield — nothing exists today) before the composition renders plugin refs, AND its `ObjectStore.spec.configuration.s3Credentials` MUST be confirmed to support `inheritFromIAMRole`.
- **FR-008**: The Crossplane aggregate `ClusterRole` (`additional-rbac.yaml:6-14`) MUST grant `objectstores` (apiGroup `postgresql.cnpg.io`) so the Crossplane SA can create the CR.
- **FR-009**: `main_test.k` (`main_test.k:43-59`) SHOULD assert the new `ObjectStore` count, `ScheduledBackup.spec.method == "plugin"`, and `Cluster.spec.plugins` presence.

### Non-Goals

- Not changing the shared S3 bucket (`infrastructure/base/cloudnative-pg/s3-bucket.yaml`, `cnpg-backups`) — the composition keeps taking `bucketName` and granting access.
- Not changing the user-facing XRD backup API (`spec.backup.{schedule,bucketName,retentionPolicy}`, `spec.objectStoreRecovery.{bucketName,path}`) — this is an internal rendering change, **except** one optional, default-off access-key field added per CL-4.
- Not migrating other CNPG features (Poolers, declarative DatabaseRole, etc.).
- Not performing the operator `1.31.0` bump itself — that is a separate PR, blocked on this one.
- Not fixing anything outside backup/recovery rendering.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must answer yes/no with cluster evidence.

- **SC-001**: A `SQLInstance` claim with backup renders exactly one `ObjectStore` CR and a `Cluster` with `spec.plugins` — verified via `crossplane render` and `main_test.k`.
- **SC-002**: On a live cluster, a `ScheduledBackup` with `method: plugin` produces a `Backup` object reaching `status.phase: completed`, with objects present in S3.
- **SC-003**: WAL archiving via the plugin succeeds — `Cluster` `status` shows healthy continuous archiving and **no** in-tree `barmanObjectStore` in the rendered `Cluster`.
- **SC-004**: Recovery from an `ObjectStore` (PITR) bootstraps a new `Cluster` successfully.
- **SC-005**: `grep barmanObjectStore` over the rendered composition output returns **zero** hits.
- **SC-006**: `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane create objectstores -A` → `yes`; the `SQLInstance` XR reaches `Synced=True` and `Ready=True` within 60s of apply.
- **SC-007**: Polaris audit score ≥ 85 on the plugin controller `Deployment`; a default-deny `CiliumNetworkPolicy` scopes the plugin's S3 egress.

---

## Open questions

<!-- Resolved via /clarify → appended to clarifications.md as CL-N. -->

- [x] CL-2 — Plugin delivery mechanism — **SUPERSEDED by CL-6** (no Helm chart exists → GitRepository + Flux Kustomization)
- [x] CL-3 — `ScheduledBackup` / `Cluster.spec.plugins` / recovery API shape (verified from upstream docs)
- [x] CL-4 — Credential model: credential-less IAM via Pod Identity (default) + opt-in access-key Secret via ESO
- [x] CL-5 — Plugin securityContext (PSS-restricted) + CNP egress via `toFQDNs` + Pod Identity Agent host:80

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Migration guide: <https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/>
- Plugin chart: `plugin-barman-cloud-v0.7.0` (2026-06-10)
- Composition: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/main.k`
- Database migrations rule: [.claude/rules/database-migrations.md](../../../.claude/rules/database-migrations.md)
