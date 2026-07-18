# Plan: Migrate SQLInstance backups to the Barman Cloud CNPG-I plugin

**Spec**: [SPEC-010](spec.md)
**Status**: draft
**Last updated**: 2026-07-18

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation. Append-only `clarifications.md` is where decisions are durable. Reconciled with CL-2…CL-5 on 2026-07-18.

---

## Design

### API / Interface

User-facing XRD API is unchanged **except** one optional, default-off access-key field (CL-4). Internal rendering changes from in-tree to plugin. Plugin API shapes below are verified in [CL-3](clarifications.md); credential model is [CL-4](clarifications.md).

New rendered `ObjectStore` (per claim with backup) — **default omits `s3Credentials`** (ambient Pod Identity, CL-4):

```yaml
apiVersion: barmancloud.cnpg.io/v1   # verify ObjectStore group/version against plugin v0.7.0 CRD (T001)
kind: ObjectStore
metadata:
  name: xplane-<claim>-cnpg-objectstore
  namespace: <claim namespace>
spec:
  configuration:
    destinationPath: s3://<bucketName>
    s3Credentials:
      inheritFromIAMRole: true        # DEFAULT (CL-4, refined by CL-6): same barman-cloud API as
                                      # the in-tree field (main.k:277); ambient Pod Identity via the
                                      # AWS SDK default chain. OPT-IN access-key mode swaps in
                                      # accessKeyId/secretAccessKey (ESO Secret). No IRSA annotation.
    wal: { compression: bzip2 }
    data: { compression: bzip2 }
  retentionPolicy: <retentionPolicy>  # moved off Cluster.spec.backup (CL-3)
```

`Cluster` gains the plugin ref and drops `spec.backup.barmanObjectStore` (CL-3):

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: xplane-<claim>-cnpg-objectstore
```

`ScheduledBackup` gains the plugin method (CL-3, verified):

```yaml
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
```

Recovery (CL-3) — `Cluster.spec.externalClusters[].plugin` (singular) + `bootstrap.recovery.source`:

```yaml
spec:
  bootstrap:
    recovery:
      source: <recovery-source-name>
  externalClusters:
    - name: <recovery-source-name>
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: xplane-<claim>-cnpg-objectstore-recovery
          serverName: <source cluster>
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| `ObjectStore` (barman-cloud) | When `spec.backup` set | Replaces in-tree backup config; destination + retention + compression; no `s3Credentials` by default (CL-4) |
| `ObjectStore` (recovery) | When `spec.objectStoreRecovery` set | Feeds `externalClusters[].plugin` recovery (CL-3) |
| `Cluster.spec.plugins` entry | When backup set | `isWALArchiver: true` |
| `ScheduledBackup` (`method: plugin`) | When `spec.backup.schedule` set | Was in-tree default |
| `ExternalSecret` (access-key) | When opt-in access-key mode (CL-4 B) | Keys from OpenBao → Secret referenced in `ObjectStore.s3Credentials` |
| RBAC `objectstores` grant | Always (one-time) | Added to `additional-rbac.yaml` aggregate ClusterRole |
| barman-cloud plugin (GitRepository + Flux Kustomization → CRD + Deployment + RBAC + Service + cert-manager certs + CNP) | Always (one-time, cluster-wide) | Greenfield install, patched to ns `infrastructure` (CL-6) |

### Key Entities

- **`ObjectStore`** (`barmancloud.cnpg.io`): per-claim S3 backup destination, named `xplane-<claim>-cnpg-objectstore`.
- **barman-cloud plugin controller**: cluster-wide Deployment in ns `infrastructure` (installed via Flux Kustomization from a GitRepository, CL-6) reconciling `ObjectStore` + injecting the WAL-archiver/backup sidecar into instance pods (runs under the existing SA `<claim>-cnpg-cluster` → existing Pod Identity carries over).

### Dependencies

- [ ] barman-cloud CNPG-I plugin installed cluster-wide via **Flux Kustomization from a GitRepository** at the release tag (CRD + Deployment + RBAC + Service + cert-manager certs + CNP), patched to ns `infrastructure` — greenfield, nothing exists today (CL-6).
- [ ] cert-manager present (plugin↔operator mTLS) — already in the repo.
- [ ] `objectstores` added to the Crossplane aggregate ClusterRole (`additional-rbac.yaml:13`).
- [ ] Verify the `ObjectStore` accepts an omitted `s3Credentials` block → ambient Pod Identity auth (CL-4 default; T001).
- [ ] Target the migration to land **before** any operator `1.31.0` bump (in-tree removed there).

### Alternatives considered

Keep in-tree `barmanObjectStore` — rejected: removed in operator 1.31.0, blocks the CNPG upgrade path. Switch backup tooling entirely (e.g. off Barman) — rejected: out of scope, plugin is the sanctioned CNPG path. `HelmRelease` delivery — not possible (CL-6): the plugin ships no Helm chart (upstream #351); vendoring the raw manifest — rejected (CL-6) in favour of a GitRepository + Flux Kustomization (matches the repo's CRD-install pattern, tag-versioned).

---

## Implementation Notes

- **Two render sites** must both change: backup (`main.k:273-288`) and recovery `externalClusters` (`main.k:325-339`, bootstrap source `main.k:248-253`). Don't migrate one and miss the other.
- **No KCL dict mutation** (function-kcl #285) — build the `ObjectStore` and the `spec.plugins` list with inline conditionals, single-line list comprehensions.
- **Credential model (CL-4)**: default omits `s3Credentials` → the plugin sidecar (in the instance pods under SA `<claim>-cnpg-cluster`) inherits ambient creds from the existing `PodIdentityAssociation` + IAM role/policy (`main.k:671-761`). No new EPI. Opt-in access-key mode adds an `ExternalSecret` (OpenBao-sourced) referenced in `ObjectStore.s3Credentials`.
- **CNP (CL-5)** — default-deny + explicit allow egress on the plugin controller/sidecar: kube-dns with L7 `rules.dns matchPattern: "*"` (mandatory, rule #1); `toFQDNs` for the S3 endpoints (`s3.<region>.amazonaws.com` + variants; `matchPattern` subdomain-depth care, rule #2); `toEntities: ["host"]` TCP 80 for the Pod Identity Agent `169.254.170.23` (required for the ambient-cred default, rule #3); egress to the CNPG cluster/instances as needed. **Not** `toEntities: world` — long-lived workload (rule #4).
- **securityContext (CL-5)**: PSS-restricted — `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault` — on the controller and, where configurable, the injected sidecar. Requests + limits set.
- **ActivationPolicy needs NO change** — `ObjectStore` is a CNPG-ecosystem CRD, not an `m.upbound.io` managed resource.
- Retention field relocates: delete from `Cluster.spec.backup.retentionPolicy`, add to `ObjectStore.spec.retentionPolicy`.
- **Failure modes**: plugin controller down → WAL archiving stalls (Cluster archiving condition degrades, backups queue) — no data loss, recovers on controller restart. Rollback: revert the composition + keep operator ≤ 1.30.x (in-tree still present).

### File structure

```
infrastructure/base/crossplane/configuration/kcl/cloudnativepg/
├── main.k            # both render sites + ObjectStore + spec.plugins + ScheduledBackup method
├── main_test.k       # + ObjectStore count / method=plugin / spec.plugins assertions
└── settings-example.yaml
infrastructure/base/crossplane/providers/additional-rbac.yaml   # + objectstores
infrastructure/base/cloudnative-pg-barman-plugin/               # Flux Kustomization + kustomize patches (ns/securityContext/CNP) (CL-6)
flux/sources/gitrepo-barman-cloud-plugin.yaml                   # GitRepository @ release tag (CL-6)
crds/base/kustomization-barman-cloud-plugin.yaml                # ObjectStore CRD, mirrors kustomization-cloudnative-pg.yaml
```

### Validation path

- `kcl fmt` passes; `./scripts/validate-kcl-compositions.sh` → exit 0
- `crossplane render` on basic + recovery examples succeeds
- `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0` (plugin manifests schema-validate)
- Polaris ≥ 85 on plugin Deployment

---

## Tasks

> Each task has a stable ID. Cite fresh evidence before marking `[x]` (see [.claude/rules/process.md](../../../.claude/rules/process.md)).

> **Requirements coverage**: FR-001 → T004; FR-002 → T005; FR-003 → T006 (CL-3); FR-004 → T007; FR-005 → T004; FR-006 → T004 (default: omit `s3Credentials`) / T012 (opt-in access-key, CL-4); FR-007 → T001/T002 (CL-6); FR-008 → T003; FR-009 → T008.

### Phase 1: Prerequisites

- [ ] **T001**: Verify the `ObjectStore` CRD apiVersion/kind and that omitting `s3Credentials` yields ambient IAM (Pod Identity) auth, against `plugin-barman-cloud` v0.7.0. (The `ScheduledBackup` / `Cluster.spec.plugins` / `externalClusters[].plugin` shapes are confirmed in CL-3.)
- [ ] **T002**: Install the plugin via a **Flux Kustomization from a GitRepository** at the plugin release tag (CL-6): `ObjectStore` CRD under `crds/base/`; Deployment/RBAC/Service/cert-manager certs applied via `infrastructure/base/cloudnative-pg-barman-plugin/` with kustomize patches — **namespace → `infrastructure`** (match the CNPG operator), PSS-restricted securityContext + resource limits (CL-5), and a default-deny `CiliumNetworkPolicy` (kube-dns L7 + `toFQDNs` S3 + `toEntities: host` TCP 80 Pod Identity Agent).
- [ ] **T003**: Add `objectstores` to the Crossplane aggregate ClusterRole (`additional-rbac.yaml:13`).

### Phase 2: Implementation

- [ ] **T004**: Render per-claim `ObjectStore` (backup) with destination + retention + compression, **no `s3Credentials`** by default (CL-4); drop `Cluster.spec.backup.barmanObjectStore` (`main.k:273-288`).
- [ ] **T005**: Add `Cluster.spec.plugins` entry (`isWALArchiver: true`, `barmanObjectName`).
- [ ] **T006**: Set `ScheduledBackup.spec.method: plugin` + `pluginConfiguration.name` (CL-3) (`main.k:649-670`).
- [ ] **T007**: Migrate recovery `externalClusters[].plugin` + `bootstrap.recovery.source` to a recovery `ObjectStore` (CL-3) (`main.k:325-339`).
- [ ] **T012**: (opt-in, CL-4 B) Add the optional default-off access-key mode — an optional XRD field selecting access-key auth, wiring an ESO-backed Secret (keys from OpenBao) into `ObjectStore.s3Credentials`.

### Phase 3: Validation & Documentation

- [ ] **T008**: `main_test.k` asserts `ObjectStore` count + `method: plugin` + `spec.plugins` presence.
- [ ] **T009**: Basic + recovery examples render with `crossplane render`; `grep barmanObjectStore` → 0 hits (SC-005).
- [ ] **T010**: `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`.
- [ ] **T011**: README / `settings-example.yaml` note the plugin backup model + the opt-in access-key mode.

### Deviations from plan

<!-- Append as surprises show up. -->

---

## Review Checklist

> Completed as a design review post-`/clarify` (2026-07-18). `[x]` = the design/CLs satisfy the rule; unchecked items require implementation artifacts not yet present.

### Project Manager

- [x] Problem statement is clear and specific
- [x] User stories capture real user needs
- [x] Acceptance scenarios are testable
- [x] Scope is well-defined (goals AND non-goals)
- [x] Success criteria are measurable

### Platform Engineer

- [x] Design follows existing patterns (`SQLInstance` current backup rendering; CNPG `HelmRelease`)
- [x] Resource naming follows `xplane-*` convention
- [x] KCL avoids mutation pattern (function-kcl #285); list comprehensions single-line
- [x] Both render sites (backup + recovery) covered (T004 + T007)
- [ ] Examples provided (basic + recovery) — implementation artifact, T009/T011

### Security & Compliance

- [x] `CiliumNetworkPolicy` for the plugin controller (default-deny + S3 egress) — CL-5
- [x] Least-privilege RBAC — only `objectstores` added
- [x] No hardcoded credentials — S3 via Pod Identity (default, CL-4); opt-in access-key via ESO (never hardcoded)
- [x] Plugin securityContext non-root, read-only FS, `seccompProfile: RuntimeDefault` — CL-5
- [x] IAM policy still scoped to `xplane-*` / the shared bucket; no new deletion perms

### SRE

- [x] Backup + WAL archiving health observable (Cluster status, Backup phase)
- [x] Metrics/logs unaffected (podMonitor still scrapes)
- [x] Plugin resource requests + limits set — CL-5
- [x] Failure modes documented (plugin down → archiving stalls) — Implementation Notes
- [x] Recovery / rollback path clear (revert composition + operator stays ≤1.30.x)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- CNPG migration guide: <https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/>
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/`
