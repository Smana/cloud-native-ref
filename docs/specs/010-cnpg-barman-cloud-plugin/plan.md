# Plan: Migrate SQLInstance backups to the Barman Cloud CNPG-I plugin

**Spec**: [SPEC-010](spec.md)
**Status**: draft
**Last updated**: 2026-07-18

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation. Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

User-facing XRD API is **unchanged**. Internal rendering changes from in-tree to plugin. New rendered `ObjectStore` (per claim with backup):

```yaml
apiVersion: barmancloud.cnpg.io/v1   # confirm group/version against plugin-barman-cloud v0.7.0 CRD
kind: ObjectStore
metadata:
  name: xplane-<claim>-cnpg-objectstore
  namespace: <claim namespace>
spec:
  configuration:
    destinationPath: s3://<bucketName>
    s3Credentials:
      inheritFromIAMRole: true        # reuse existing Pod Identity — FR-006 (verify support)
    wal: { compression: bzip2 }
    data: { compression: bzip2 }
  retentionPolicy: <retentionPolicy>  # moved off Cluster.spec.backup
```

`Cluster` gains the plugin ref and drops `spec.backup.barmanObjectStore`:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: xplane-<claim>-cnpg-objectstore
```

`ScheduledBackup` gains the plugin method:

```yaml
spec:
  method: plugin
  pluginConfiguration:               # confirm exact field name against plugin CRD
    name: barman-cloud.cloudnative-pg.io
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| `ObjectStore` (barman-cloud) | When `spec.backup` set | Replaces in-tree backup config; holds destination + retention + compression |
| `ObjectStore` (recovery) | When `spec.objectStoreRecovery` set | Feeds `externalClusters` plugin recovery |
| `Cluster.spec.plugins` entry | When backup set | `isWALArchiver: true` |
| `ScheduledBackup` (`method: plugin`) | When `spec.backup.schedule` set | Was in-tree default |
| RBAC `objectstores` grant | Always (one-time) | Added to `additional-rbac.yaml` aggregate ClusterRole |
| barman-cloud plugin (Deployment + CRD) | Always (one-time, cluster-wide) | Greenfield install |

### Key Entities

- **`ObjectStore`** (`barmancloud.cnpg.io`): per-claim S3 backup destination, named `xplane-<claim>-cnpg-objectstore`.
- **barman-cloud plugin controller**: cluster-wide Deployment reconciling `ObjectStore` + injecting the WAL-archiver/backup sidecar into instance pods (runs under the existing SA `<claim>-cnpg-cluster` → existing Pod Identity carries over).

### Dependencies

- [ ] barman-cloud CNPG-I plugin installed cluster-wide (Deployment + `ObjectStore` CRD) — **greenfield**, nothing exists today.
- [ ] `objectstores` added to the Crossplane aggregate ClusterRole (`additional-rbac.yaml:13`).
- [ ] Plugin `s3Credentials.inheritFromIAMRole` support confirmed (else the IAM/Pod-Identity model changes — see spec Open questions).
- [ ] Target the migration to land **before** any operator `1.31.0` bump (in-tree removed there).

### Alternatives considered

Keep in-tree `barmanObjectStore` — rejected: removed in operator 1.31.0, blocks the CNPG upgrade path. Switch backup tooling entirely (e.g. off Barman) — rejected: out of scope, plugin is the sanctioned CNPG path.

---

## Implementation Notes

- **Two render sites** must both change: backup (`main.k:273-288`) and recovery `externalClusters` (`main.k:325-339`, bootstrap source `main.k:248-253`). Don't migrate one and miss the other.
- **No KCL dict mutation** (function-kcl #285) — build the `ObjectStore` and the `spec.plugins` list with inline conditionals, single-line list comprehensions.
- **IAM bundle is unchanged** if `inheritFromIAMRole` is supported: the plugin sidecar runs in the instance pods under SA `<claim>-cnpg-cluster`, which already has the `PodIdentityAssociation` + IAM role/policy (`main.k:671-761`). No new EPI, no ExternalSecret.
- **ActivationPolicy needs NO change** — `ObjectStore` is a CNPG-ecosystem CRD, not an `m.upbound.io` managed resource (activation policy only gates Upbound provider CRDs).
- Retention field relocates: delete from `Cluster.spec.backup.retentionPolicy`, add to `ObjectStore.spec.retentionPolicy`.

### File structure

```
infrastructure/base/crossplane/configuration/kcl/cloudnativepg/
├── main.k            # both render sites + ObjectStore + spec.plugins + ScheduledBackup method
├── main_test.k       # + ObjectStore count / method=plugin / spec.plugins assertions
└── settings-example.yaml
infrastructure/base/crossplane/providers/additional-rbac.yaml   # + objectstores
crds/base/  or  infrastructure/base/cloudnative-pg-barman-plugin/  # plugin install (delivery TBD — Open Q)
```

### Validation path

- `kcl fmt` passes; `./scripts/validate-kcl-compositions.sh` → exit 0
- `crossplane render` on basic + recovery examples succeeds
- `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0` (plugin manifests schema-validate)
- Polaris ≥ 85 on plugin Deployment

---

## Tasks

> Each task has a stable ID. Cite fresh evidence before marking `[x]` (see [.claude/rules/process.md](../../../.claude/rules/process.md)).

> **Requirements coverage**: FR-001 → T004; FR-002 → T005; FR-003 → T001/T006; FR-004 → T007; FR-005 → T004; FR-006 → T001 (+ Implementation Notes); FR-007 → T001/T002; FR-008 → T003; FR-009 → T008.

### Phase 1: Prerequisites

- [ ] **T001**: Confirm plugin CRD group/version, `ScheduledBackup` plugin API shape, and `s3Credentials.inheritFromIAMRole` support against `plugin-barman-cloud-v0.7.0` (resolves 3 Open questions).
- [ ] **T002**: Decide + implement plugin delivery (HelmRelease vs raw manifests); install controller Deployment + `ObjectStore` CRD cluster-wide, with PSS-restricted securityContext, resource limits, and a default-deny `CiliumNetworkPolicy` for S3 egress.
- [ ] **T003**: Add `objectstores` to the Crossplane aggregate ClusterRole (`additional-rbac.yaml:13`).

### Phase 2: Implementation

- [ ] **T004**: Render per-claim `ObjectStore` (backup) with destination + retention + compression; drop `Cluster.spec.backup.barmanObjectStore` (`main.k:273-288`).
- [ ] **T005**: Add `Cluster.spec.plugins` entry (`isWALArchiver: true`, `barmanObjectName`).
- [ ] **T006**: Set `ScheduledBackup.spec.method: plugin` + plugin ref (`main.k:649-670`).
- [ ] **T007**: Migrate recovery `externalClusters` to plugin recovery `ObjectStore` (`main.k:325-339`).

### Phase 3: Validation & Documentation

- [ ] **T008**: `main_test.k` asserts `ObjectStore` count + `method: plugin` + `spec.plugins` presence.
- [ ] **T009**: Basic + recovery examples render with `crossplane render`; `grep barmanObjectStore` → 0 hits (SC-005).
- [ ] **T010**: `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`.
- [ ] **T011**: README / `settings-example.yaml` note the plugin backup model.

### Deviations from plan

<!-- Append as surprises show up. -->

---

## Review Checklist

### Project Manager

- [ ] Problem statement is clear and specific
- [ ] User stories capture real user needs
- [ ] Acceptance scenarios are testable
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Success criteria are measurable

### Platform Engineer

- [ ] Design follows existing patterns (`SQLInstance` current backup rendering)
- [ ] Resource naming follows `xplane-*` convention
- [ ] KCL avoids mutation pattern (function-kcl #285); list comprehensions single-line
- [ ] Both render sites (backup + recovery) covered
- [ ] Examples provided (basic + recovery)

### Security & Compliance

- [ ] `CiliumNetworkPolicy` for the plugin controller (default-deny + S3 egress)
- [ ] Least-privilege RBAC — only `objectstores` added
- [ ] No hardcoded credentials — S3 via IAM role (Pod Identity, `inheritFromIAMRole`)
- [ ] Plugin securityContext non-root, read-only FS, `seccompProfile: RuntimeDefault`
- [ ] IAM policy still scoped to `xplane-*` / the shared bucket; no new deletion perms

### SRE

- [ ] Backup + WAL archiving health observable (Cluster status, Backup phase)
- [ ] Metrics/logs unaffected (podMonitor still scrapes)
- [ ] Plugin resource requests + limits set
- [ ] Failure modes documented (plugin down → archiving stalls)
- [ ] Recovery / rollback path clear (revert composition + operator stays ≤1.30.x)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- CNPG migration guide: <https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/>
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/`
