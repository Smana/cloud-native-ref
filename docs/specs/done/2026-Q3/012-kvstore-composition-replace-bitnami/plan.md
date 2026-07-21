# Plan: KVStore composition: replace Bitnami Valkey with official valkey-helm chart behind a cloud.ogenki.io XRD

**Spec**: [SPEC-012](spec.md)
**Status**: draft
**Last updated**: 2026-07-20

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

> **For agentic workers:** execute task-by-task with fresh evidence before every `[x]` (`.claude/rules/process.md`). Tasks are grouped by PR.

---

## Design

### Verified chart facts (research 2026-07-20, source of truth for all tasks)

Chart: `valkey` **0.10.0** (appVersion 9.1.0) from <https://valkey.io/valkey-helm/> (repo [valkey-io/valkey-helm](https://github.com/valkey-io/valkey-helm), `valkey/` directory — NOT `valkey-operator/`/`valkey-resources/`, which are the official operator charts, deliberately not used per CL-3).

- **Naming**: `fullname` = release name when it contains "valkey". We set `fullnameOverride` explicitly anyway. Main Service = `<fullname>` (port 6379, name `tcp`); metrics Service = `<fullname>-metrics` (port 9121); headless Service `<fullname>-headless` (replica mode only).
- **Labels** (selector): `app.kubernetes.io/name: valkey`, `app.kubernetes.io/instance: <releaseName>` — **identical to today's Bitnami labels**, so the App CNP egress selector shape survives.
- **Workload**: standalone = Deployment `<fullname>`; `replica.enabled` = StatefulSet. Standalone is ephemeral unless `dataStorage.enabled` (default **false** — CL-4 is the chart default). Replica mode **requires** `replica.persistence.size` (chart `fail`s otherwise).
- **Auth**: `auth.enabled` + `auth.usersExistingSecret` + `auth.aclUsers` map; a `default` user with `permissions` is **mandatory** when auth is on; `passwordKey` selects the key in the secret. Classic `AUTH <password>` authenticates as `default` — Harbor/OnCall password secrets work unchanged.
- **Security**: default `securityContext` already restricted-compliant (non-root, drop ALL, RO rootfs, no-priv-esc); `podSecurityContext.seccompProfile: RuntimeDefault` at pod level. **Gap**: `metrics.exporter.securityContext` defaults to `{}` — we must set it. `resources` default `{}` — we must set them.
- **Probes**: startup + liveness on by default (`valkey-cli ping` exec); `readinessProbe.enabled` defaults **false** — we enable it.
- **Metrics**: exporter sidecar `ghcr.io/oliver006/redis_exporter:v1.79.0`, metrics Service + optional `metrics.serviceMonitor` (`monitoring.coreos.com` ServiceMonitor — already converted by the VictoriaMetrics operator in this cluster; Harbor's Bitnami valkey uses the same mechanism today).
- Chart ships an optional native NetworkPolicy (`networkPolicy: {}`) — left off; we render a CiliumNetworkPolicy.

### API / Interface (FR-001)

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: KVStore
metadata:
  name: xplane-harbor
  namespace: tooling
spec:
  size: nano            # Optional: nano|small|medium|large, default "small"
  replicas: 0           # Optional: 0 = standalone (default), 1-5 = read replicas (no auto-failover, CL-2)
  auth:                 # Optional: omitted = auth disabled
    existingSecret: harbor-valkey-password
    passwordKey: REDIS_PASSWORD   # Optional, default "password"
  persistence:          # Optional: omitted = ephemeral (CL-4); required-with-default in replica mode
    size: 4Gi
  metrics: true         # Optional, default true
```

Consumers reach the instance at `<xr-name>-valkey:6379` (namespace-local DNS).

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| HelmRelease `<xr-name>-valkey` | Always | chart `valkey` 0.10.0, sourceRef HelmRepository `valkey`/flux-system; static-ready per repo convention (FR-002) |
| CiliumNetworkPolicy `<xr-name>-valkey` | Always | default-deny; see Security below (FR-003) |

(ServiceMonitor, Services, workload are chart-rendered inside the HelmRelease, not composed resources.)

### Size map (FR-008 — replaces Bitnami `resourcesPreset`)

| size | requests | limits | exporter (fixed) |
|------|----------|--------|------------------|
| nano | 100m / 128Mi | 150m / 192Mi | req 50m/64Mi, lim 100m/128Mi |
| small | 250m / 256Mi | 375m / 384Mi | same |
| medium | 500m / 512Mi | 750m / 768Mi | same |
| large | 1000m / 1Gi | 1500m / 1536Mi | same |

### Security (FR-003, FR-008)

CNP per instance, endpointSelector `{app.kubernetes.io/name: valkey, app.kubernetes.io/instance: <xr-name>-valkey}`:

- Ingress: TCP 6379 from all endpoints in the same namespace (`fromEndpoints: [{}]`); TCP 9121 from `{io.kubernetes.pod.namespace: observability}` (vmagent scrape — without this rule SC-005 fails).
- Egress (replica mode only): kube-dns 53 with `rules.dns.matchPattern: "*"` (cilium rule 1) + TCP 6379 to the instance's own selector (replica→primary sync). Standalone renders **no egress** (needs none).

Exporter sidecar securityContext (chart default is `{}`): `runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}` (pod-level seccompProfile covers it).

### Consumer wiring (FR-005, FR-006)

| Consumer | XR/claim name | Service DNS (new) | Today |
|---|---|---|---|
| App composition | `_managedName` (`xplane-<app>`) | `xplane-<app>-valkey` | `<claim>-valkey-primary` |
| Harbor | `xplane-harbor` | `xplane-harbor-valkey` | `harbor-valkey-primary` |
| OnCall | `xplane-oncall` | `xplane-oncall-valkey` | `oncall-valkey-primary` |

App API unchanged (`kvStore.enabled/size/type`); `type` is accepted but **ignored** (valkey-only backend) — documented, CL-5 if contested during review. `REDIS_URL` becomes `redis://<xr-name>-valkey:6379`. The Bitnami HRs' `useExternalDNS` Route53 records are dropped — both consumers use in-cluster DNS; nothing references the external names (verify in T007/T008).

### Dependencies

- [ ] HelmRepository `valkey` in `flux/sources/` (unsharded — flux-controller-sharding gotcha)
- [ ] Chart 0.10.0 present in <https://valkey.io/valkey-helm/index.yaml> (verify in T001; pin whatever latest stable ≤0.x actually published)
- [ ] No Crossplane RBAC/activation changes needed (HelmRelease + CiliumNetworkPolicy already writable by existing compositions)

### Alternatives considered

ElastiCache, in-place chart swap, and operators (hyperspike; official `valkey-operator` 0.4.0 discovered during research) — rejected in CL-1/CL-2/CL-3. The XRD boundary keeps the official operator available as a future backend swap invisible to consumers.

### Failure modes & rollback

- Chart renders `fail` if replica mode lacks `persistence.size` → composition always defaults it (4Gi) when `replicas > 0`.
- Auth misconfig (missing `default` user) is a chart-level `fail` → composition owns the aclUsers block; user only supplies secret name/key.
- Ephemeral default: pod restart = cold cache (accepted, CL-2/CL-4). Harbor/OnCall tolerate this today (job queue/broker refill).
- Rollback path: revert the consumer commit (PR 2) — Bitnami HRs return; no data to restore (caches). Composition PR (PR 1) is additive and inert until consumed.

---

## Implementation Notes

- KCL: no post-creation dict mutation (function-kcl #285) — build `values` with inline conditionals; single-line comprehensions; `kcl fmt` before commit.
- `fullnameOverride = <xr-name>-valkey` is set explicitly so naming never depends on the release-name-contains-chart-name heuristic.
- Static readiness (`krm.kcl.dev/ready = "True"`) on both HelmRelease and CNP per `.claude/rules/crossplane-validation.md`; XR readiness via function-auto-ready (mirrors SQLInstance).
- App module (`kcl/app/main.k`) deletions: `_kvSizeToPreset` (line ~102), `_observedKVStore`/`_helmReleaseReady` (~line 562), the kvStore HelmRelease block (~979–1052). The `_npCache` egress selector switches `_name` → `_managedName`; the SHARED CONTRACT comment near `_cacheAutoEnv` (~line 412) is updated: the `<xr>-valkey` Service name is now owned by the **kvstore module**.
- OCI pin flow (kcl-crossplane rule 5): PR CI publishes `<version>-pr<N>`; pin that during PR validation, strip to `<version>` in the final pre-merge commit. `crossplane-modules.yml` auto-detects the new `kvstore/` module (any dir with `kcl.mod`).
- The `bitnami` HelmRepository **stays** — `kubernetes-event-exporter` and OnCall's `rabbitmq` still consume it (FR-007's conditional: only Valkey usages are removed; full removal is a future spec).

### File structure (FR-009)

```
infrastructure/base/crossplane/configuration/
├── kcl/kvstore/
│   ├── kcl.mod                  # name "kvstore", version "0.1.0", edition "v0.11.3"
│   ├── main.k
│   ├── main_test.k
│   ├── settings-example.yaml
│   └── README.md
├── kvstore-definition.yaml      # XRD (apiextensions.crossplane.io/v2, Namespaced)
├── kvstore-composition.yaml     # pipeline: function-kcl (OCI crossplane-kvstore) → function-auto-ready
├── examples/kvstore-basic.yaml
├── examples/kvstore-complete.yaml
└── kustomization.yaml           # + 2 entries
flux/sources/helmrepo-valkey.yaml
```

### Validation path

- `kcl fmt` passes; `kcl run -Y settings-example.yaml` renders; `kcl test` (main_test.k) passes
- `./scripts/validate-kcl-compositions.sh` exit 0 (SC-007)
- `./scripts/validate-manifests.sh` exit 0, `Invalid: 0, Skipped: 0` (SC-001)
- Polaris score ≥ 85 on rendered bundle
- Post-merge: `/verify-spec` against SC-002..SC-006 (Hubble, VictoriaMetrics `up`, XR conditions)

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1 — PR 1: composition (FR-001..004, FR-008, FR-009)

- [ ] **T001**: `flux/sources/helmrepo-valkey.yaml` — HelmRepository `valkey`, `url: https://valkey.io/valkey-helm/`, `interval: 12h`, namespace flux-system, **no shard label** (copy `helmrepo-cloudnative-pg.yaml` shape). First `curl -s https://valkey.io/valkey-helm/index.yaml | yq '.entries.valkey[0].version'` and pin that version everywhere this plan says `0.10.0`. (FR-002)
- [ ] **T002**: KCL module `kcl/kvstore/` — `kcl.mod` + `main.k` reading `option("params").oxr` and rendering the HelmRelease + CNP per Design (values mapping: size map table, `readinessProbe.enabled: true`, auth block only when `spec.auth?.existingSecret`, `replica.*` when `replicas > 0` with `persistence.size or "4Gi"`, `dataStorage` when standalone AND `persistence?.size`, `metrics` + `serviceMonitor` + exporter securityContext/resources when `metrics != False`). Static-ready annotations on both resources. `kcl fmt` clean. (FR-001, FR-002, FR-003, FR-004, FR-008)
- [ ] **T003**: `main_test.k` — TDD alongside T002: resource count (2 standalone / 2 replica), HelmRelease name/releaseName/`fullnameOverride` = `<name>-valkey`, chart version pin, no `bitnamilegacy` string anywhere in rendered values, auth block presence/absence, replica-mode `persistence.size` default, exporter securityContext fields, CNP selector labels + 9121 observability ingress + standalone-has-no-egress. Run `kcl test` → pass. (FR-009, SC-007)
- [ ] **T004**: `kvstore-definition.yaml` (XRD: spec fields per Design API, CEL not required; defaults in schema) + `kvstore-composition.yaml` (copy `sql-instance-composition.yaml` pipeline shape; `source: oci://ghcr.io/smana/cloud-native-ref/crossplane-kvstore:0.1.0`) + register both in `configuration/kustomization.yaml` + `examples/kvstore-basic.yaml` (name only) and `examples/kvstore-complete.yaml` (all fields) + module `README.md` + `settings-example.yaml`. (FR-001, FR-009)
- [ ] **T005**: Gates: `./scripts/validate-kcl-compositions.sh` exit 0; `./scripts/validate-manifests.sh` exit 0 with `Invalid: 0, Skipped: 0` (proves the new XRD schema-validates its examples). Open PR 1; after CI publishes `0.1.0-pr<N>`, pin it in `kvstore-composition.yaml`, verify anonymous pull (`crossplane xpkg pull` or `kcl mod pull`), run e2e on feature-branch cluster if available; strip to `0.1.0` in final pre-merge commit. (SC-001, SC-007)

### Phase 2 — PR 2: consumers (FR-005, FR-006, FR-007)

- [ ] **T006**: App module: replace kvStore HelmRelease block with a `KVStore` XR named `_managedName` (mirror the `sqlInstance` block; pass `size`; no auth); update `_cacheAutoEnv` to `redis://` + `_managedName` + `-valkey:6379`; `_npCache` matchLabels instance → `_managedName + "-valkey"`; delete `_kvSizeToPreset`, `_observedKVStore`, `_helmReleaseReady`; update SHARED CONTRACT comment; `kcl.mod` 0.4.0 → 0.5.0; update `app-composition.yaml` pin (same -pr<N> flow as T005); update `kcl/app/main_test.k` + `apps/base/complete/app.yaml` (`CACHE_ADDRESS`) + `configuration/examples/app-complete.yaml` if it names the old Service. (FR-005)
- [ ] **T007**: Harbor: new `tooling/base/harbor/kvstore.yaml` claim (`xplane-harbor`, `size: nano`, auth `harbor-valkey-password`/`REDIS_PASSWORD`); delete `helmrelease-valkey.yaml`; kustomization entry swap; `helmrelease-harbor.yaml` → `redis.external.addr: "xplane-harbor-valkey:6379"`, **remove `username: "user"`** (classic AUTH = `default` ACL user). Confirm nothing references the old external-DNS name: `grep -rn "harbor-valkey-primary" .` → only the files being edited. (FR-006) <!-- pragma: allowlist secret -->
- [ ] **T008**: OnCall: same as T007 with `observability/base/grafana-oncall/kvstore.yaml` (`xplane-oncall`, auth `oncall-valkey`/`password`), delete `helmrelease-valkey.yaml`, `externalRedis.host: xplane-oncall-valkey` (username `default` already correct). (FR-006)
- [ ] **T009**: Sweep + docs: `grep -rn "bitnamilegacy\|valkey.*bitnami\|bitnami.*valkey" --include='*.yaml' --include='*.k' .` → zero Valkey hits (rabbitmq/event-exporter bitnami refs remain, FR-007 conditional); update `docs/apps-user-guide.md` kvStore section + `apps/platform/app-wizard/ui-hints.yaml` if they mention `-primary` or Bitnami; `./scripts/validate-manifests.sh` exit 0 `Invalid: 0, Skipped: 0` with zero `bitnamilegacy` in `.bundle/`. (FR-007, SC-001)

### Phase 3 — post-merge

- [ ] **T010**: `/verify-spec docs/specs/012-kvstore-composition-replace-bitnami` on the live cluster: SC-002 (XR Ready ≤5min, official image), SC-003 (app REDIS_URL + no Hubble drops app→valkey), SC-004 (Harbor jobservice + OnCall logs clean), SC-005 (exporter `up==1` ×3), SC-006 (cross-namespace 6379 attempt DROPPED in Hubble). Write `VERIFICATION.md`.

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-20> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->
- 2026-07-21 — T005 pin-strip moved from "final pre-merge commit" to PR 2: the
  `validate-composition-versions` gate REQUIRES the `-pr<N>` tag on PR runs, so
  PR 1 merges pinned to `0.1.0-pr1664`; PR 2 strips it to `0.1.0` (published by
  the main-branch run after PR 1 merges). Same for the app module pin in PR 2.

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (frozen bitnamilegacy supply chain, 3× duplication)
- [x] User stories capture real user needs (platform engineer, app developer, platform components)
- [x] Acceptance scenarios are testable (each has Given/When/Then with observable outcomes)
- [x] Scope is well-defined (goals AND non-goals — failover/ElastiCache/operator explicitly out, CL-1..3)
- [x] Success criteria are measurable (SC-001..007 all falsifiable with commands)

### Platform Engineer

- [x] Design follows existing patterns (`SQLInstance` nesting, `cloudnativepg` module layout, sql-instance pipeline shape)
- [x] API is consistent with other compositions (size enums, optional blocks, namespaced XR)
- [x] Resource naming follows `xplane-*` convention (claims `xplane-*`; App uses `_managedName`)
- [x] KCL avoids mutation pattern (function-kcl #285 — inline conditionals mandated in Implementation Notes)
- [x] Examples provided (basic + complete, T004)

### Security & Compliance

- [x] Zero-trust networking (CNP per instance: 6379 ns-local, 9121 observability, egress only in replica mode)
- [x] Least-privilege RBAC (chart SA with `automount: false`, no RBAC objects; no new Crossplane grants needed)
- [x] Secrets via External Secrets (existing ESO secrets reused via `auth.usersExistingSecret`; no inline passwords)
- [x] Security context enforced (chart defaults restricted; exporter gap closed in T002)
- [x] IAM policies scoped to `xplane-*` resources (n/a — no AWS resources in this composition)

### SRE

- [x] Health checks defined (startup + liveness chart defaults; readinessProbe enabled by composition)
- [x] Observability configured (exporter + ServiceMonitor→VM operator; logs to stdout→VictoriaLogs)
- [x] Resource requests + limits appropriate (size map, exporter included)
- [x] Failure modes documented (Design → Failure modes & rollback)
- [x] Recovery / rollback path clear (revert PR 2; PR 1 additive-inert; caches refill)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/cloudnativepg/` + `sql-instance-composition.yaml`
- Chart source: <https://github.com/valkey-io/valkey-helm> (`valkey/` chart 0.10.0, appVersion 9.1.0)
