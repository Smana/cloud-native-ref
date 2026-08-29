# Design: Observability hygiene sweep + full docs/ADR review

**Date:** 2026-08-29 · **Status:** Approved (user, 2026-08-29) · **Input:** [2026-08-29-observability-stack-review.md](2026-08-29-observability-stack-review.md) (4-track audit: repo, ecosystem, multicloud, Grafana)

## Goal

Handle "most of the findings" from the observability stack review in a single branch, and bring the
website docs + ADRs fully up to date. No live-cluster claims: everything verified by the repo's
static gates; runtime verification is deferred to post-merge `/verify-spec`.

## Decisions taken during brainstorming

| Decision | Choice |
|---|---|
| Scope | Fixes/removals + small deliberate decisions + two small design-adjacent items (KEDA scrape, VL values dedup). CNP/SLO/event-exporter-replacement/GCP-host-metrics/resource-sizing deferred |
| Retention (metrics/logs/traces) | **14d / 7d + `retentionDiskSpaceUsage: 8GiB` / 3d** — fits existing 10Gi PVCs |
| loggen | **aws-0 only** (demo stays alive where the demo app lives; gcp-0 loses the synthetic noise) |
| Watchdog / dead-man's switch | **Document the stance** (Slack + RunLore is the pager; Watchdog stays blackholed); real DMS is a named follow-up |
| Docs/ADR review | **Full review of all ~97 pages + 28 ADRs; fix everything confirmed stale in this branch** |
| VL single/cluster drift | **Shared `vl-common-helm-values` ConfigMap** consumed by both variants via `valuesFrom` (same pattern as `vm-common-helm-values`), per-variant sink endpoints inline |
| Grafana bump | `image.tag: "13.1.4"` (smallest delta carrying the 2026-08-18 security fix; 13.2.0 left to Renovate once the subchart catches up) |
| Branch/PR | One worktree branch, one PR, commits grouped by theme |

## Changes

### C1 — Security & supply chain

- `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`:
  - `grafana.image.tag: "13.1.4"` (currently unset → subchart default 13.1.0, missing CVE-2026-17183 fix).
  - Replace the two curl init containers (`load-vm-ds-plugin` frozen at v0.14.0, `load-vl-ds-plugin`
    unpinned GitHub "latest") with pinned catalog entries in `grafana.plugins:`:
    `victoriametrics-metrics-datasource@0.25.2`, `victoriametrics-logs-datasource@0.31.0`.
    Remove the associated extraInitContainers, plugin volumes/mounts, and any
    `GF_INSTALL_PLUGINS`/`plugin` env plumbing that only served the init-container path.
- `.github/renovate.json`: add a `customManagers` regex to track the two `<id>@<version>` plugin pins,
  using the GitHub releases datasource against the two VictoriaMetrics plugin repos (their tags are
  `v<version>`).

### C2 — Bug fixes

- `observability/base/kubernetes-event-exporter/helmrelease.yaml`:
  - Receiver URL → the commented-in-file vlsingle endpoint (`.../insert/loki/api/v1/push` on the
    single-server service :9428); delete the dead vlcluster URL.
  - `logLevel: info`, `logFormat: json` (structured-logs rule), `metrics.enabled: true`.
  - Inspect the chart-rendered ServiceMonitor/PrometheusRule once metrics are on; fix the malformed
    alert (empty `labels:`, no comparison in expr) via values if exposed, else drop that alert block.
- Move `observability/aws-0/victoria-metrics-k8s-stack/vmrules/runlore.yaml` →
  `observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml`; update both kustomizations;
  drop the stale `./prometheusrule.yaml` header comment.
- Retention:
  - `helmrelease-vmsingle.yaml`: `retentionPeriod: "1d"` → `"14d"`, comment updated ("fits 10Gi PVC
    at this fleet size; VM OSS has no disk-based retention — free-space safety valve only").
  - vlsingle (via new `vl-common-helm-values`, C5): `retentionPeriod: 7d`,
    `retentionDiskSpaceUsage: 8GiB`.
  - `helmrelease-vtsingle.yaml`: `retentionPeriod: 3` → `3d`; fix the "# 3 days" comment (unit-less
    VictoriaMetrics durations are **months**).
- `clusters/aws-0/observability/observability.yaml`: delete the vestigial `healthCheckExprs`
  (SQLInstance — nothing under `observability/aws-0/` renders one);
  `clusters/gcp-0/observability/observability.yaml`: delete the phantom-database comment.
- VT Kustomization timeout: align both clusters to `5m`.
- Explicit `storageClassName: ${storage_class}` on vmsingle and vlsingle storage specs.
  **Constraint:** `${storage_class}` (gp3 / standard-rwo) must equal the class the admission
  controller already defaults, so existing PVCs are unchanged. Verified statically against the tofu
  locals; if a rendered PVC would differ, drop this item rather than risk an immutable-field fight.

### C3 — Removals

- **OnCall estate**: delete `observability/base/grafana-oncall/` (11 files); remove
  `grafana-oncall-app` from `grafana.plugins:`; remove the OnCall provisioning file
  (`ogenki-grafana-provisioning.yaml`) + its volume/mount + `accessControlOnCall` feature toggle
  (if the provisioning file carries anything non-OnCall, strip only the OnCall part); remove the 4
  OnCall secret seeds from `scripts/secret-store.sh`; delete `flux/sources/helmrepo-grafana.yaml`
  (only OnCall consumed it — re-verify with a repo-wide grep before deleting).
- Disable the empty **dashboards** sidecar channel (`grafana.sidecar.dashboards.enabled: false`,
  remove the empty `dashboardproviders.yaml`/`grafana.dashboards: {}` block). The **datasource**
  sidecar stays — it provisions the VM datasource.
- **loggen off gcp-0**: remove `../base/loggen` from `observability/gcp-0/kustomization.yaml`
  (stays in aws-0). Its VMRule lives in the loggen dir so it leaves gcp-0 with it.
- `databases` GrafanaFolder: check `Smana/crossplane-configuration` (public; the pinned release's
  composition output) for a consumer. Orphan → delete `observability/base/grafana-operator/folders/databases.yaml`;
  consumer found → keep with a comment naming it.

### C4 — Small additions

- `infrastructure/base/keda/vmservicescrape.yaml` (new, + kustomization entry): scrape the KEDA
  operator + metrics-apiserver services whose Prometheus ports are already enabled in
  `infrastructure/base/keda/helmrelease.yaml` — both clouds get it via the shared base.

### C5 — VL values dedup (drift fix)

- New `observability/base/victoria-logs/vl-common-helm-values-configmap.yaml`: the full Vector
  `customConfig` pipeline (sources, transforms, tests) and shared server settings (retention from
  C2, vmServiceScrape, dashboards flags).
- Both `helmrelease-vlsingle.yaml` and `helmrelease-vlcluster.yaml` consume it via `valuesFrom`;
  each keeps inline only what genuinely differs: topology (server vs vlstorage/vlselect/vlinsert),
  and the Vector **sink endpoints** (single-server :9428 vs vlinsert :9481), overridden by inline
  `spec.values` deep-merge.
- **Gate:** render vlsingle before/after (`helm template` with merged values, as
  `validate-manifests.sh` does) — must be semantically identical; render vlcluster — must now
  contain the PostgreSQL pipeline. Diffs reviewed with `difft`.
- `vmalert-vlcluster.yaml` and the event-exporter comment blocks updated to match.

### C6 — New ADRs

- **0029 — RunLore over Grafana OnCall**: OnCall was built in-repo and never wired; upstream entered
  maintenance 2025-03-11 and was archived 2026-03-24; RunLore + Slack + Alertmanager is the incident
  path. Records why OnCall lost (cloud-only migration path, archived OSS, heavier footprint:
  RabbitMQ + MySQL + Redis for a one-operator platform).
- **0030 — Vector as the log shipper** (backfill): chosen over Fluent Bit / Promtail / OTel
  Collector; carries the unit-tested auto_explain VRL pipeline; referenced-but-never-decided in
  ADR-0010.
- **0031 — Per-cluster observability panes; Slack + RunLore as the pager**: two self-contained
  stacks, no federation/remote-write (cost, cert-gated Tailscale L7 stampede risk), Slack `#alerts`
  as the shared pane with `cluster` external labels; Watchdog stays blackholed; a real dead-man's
  switch is a named follow-up.
- ADR-0010 correction: the "explicitly-set CPU/memory requests and limits" claim is false for
  vmsingle and others — reworded to what is true; right-sizing itself is a follow-up.

### C7 — Full docs & ADR review

- Fan out parallel read-only subagents over `website/content/docs/**` (platform 34, decisions 30,
  get-started 12, reference 7, guides 7, concepts 6) verifying every checkable claim against
  manifests/opentofu/scripts. Known-stale from the review (fixed regardless): observability
  `_index.md` ("runlore stays AWS-only", "No ADR records the comparison"), `sre-agent.md` (identity
  is EPI-only), `logs.md` (event-exporter "documented as broken" — now fixed), gcp VT Kustomization
  comment, the aws-0 "ONE-TIME" prune note (resolve: confirm whether the annotation step already
  happened via git history / flux state comment, then delete the note; if indeterminate, keep the
  annotation instruction in the PR body and delete the note).
- Docs updated to reflect this branch's own changes (retention values, plugin install mechanism,
  OnCall removal, loggen scope, KEDA scrape, VL shared values).
- New `.doc-claims.yaml` guards: runlore-on-both-clouds, retention-metrics-14d, retention-logs-7d,
  retention-traces-3d, loggen-aws-only, oncall-absent, grafana-plugin-pins.
- Every other confirmed-stale claim found by the sweep is fixed in this branch as separate
  `docs:` commits (docs-only edits, low risk).

## Verification (evidence per claim, run fresh at completion)

| Claim | Command |
|---|---|
| Manifests valid | `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0` |
| Docs links resolve | `./scripts/validate-links.sh` → exit 0 |
| Docs claims hold | `./scripts/validate-doc-claims.sh` → exit 0 (including the new guards) |
| Substitution safety | `python3 scripts/flux-schema/test-check-substitution.py` → pass |
| IaC hygiene | `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .` → exit 0 |
| VL refactor is a no-op for vlsingle | before/after render diff (semantic, `difft`) empty; vlcluster render contains `parse_pg_auto_explain` |

## Constitution compliance

No new pod-running workloads (KEDA scrape and VMRules are CRs; the VL ConfigMap is values plumbing),
so no new CNP obligations are created — the existing observability CNP gap is explicitly out of
scope (follow-up WP3). Technology choices with rejected alternatives get ADRs 0029/0030/0031 on this
branch before the PR opens. `xplane-*`, External Secrets, and EPI rules are untouched.

## Risks

- **Grafana 13.1.4 image override**: chart 12.7.* config vs newer image — same minor (13.1.x), no
  config schema change expected; confirmed React-only plugins.
- **Plugin install path change**: catalog install happens at pod start (as before, different
  source); pinned versions make it reproducible. Grafana.com outage at pod start is the residual
  risk (previously: GitHub API outage + version drift).
- **Retention bump**: 14d on 10Gi — VM storage is compact at this fleet size (~10 nodes worth of
  targets); watch disk after merge (post-merge `/verify-spec`).
- **valuesFrom refactor**: deep-merge semantics (maps merge, lists replace) — Vector sinks are maps
  keyed by name, so per-variant endpoint overrides merge cleanly; the render-diff gate is the
  backstop.
- **event-exporter alert repair** depends on what the Bitnami chart exposes; if values can't fix the
  malformed alert, dropping that alert is acceptable (the component's liveness is also covered by
  Vector-side ingestion).

## Out of scope (named follow-ups)

CiliumNetworkPolicies for the observability namespace (WP3) · SLO example, Pyrra-vs-Sloth ADR (WP5)
· event-exporter replacement ADR · GCP OpenBao host metrics (`gceSDConfigs` + node-exporter in
startup script) · resource right-sizing (needs live usage) · real dead-man's switch · live
verification items (Karpenter dashboard rev-1 probe, VL/VT chart-vs-CR dashboard duplication check,
effective-retention confirmation) — these need the personal tailnet and run post-merge.
