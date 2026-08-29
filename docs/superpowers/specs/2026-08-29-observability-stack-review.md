# Observability Stack Review — cloud-native-ref

**Date:** 2026-08-29 · **Status:** research input for a phase-2 superpowers cycle (brainstorming → design → plan) · **Author:** Claude Code session, 4 parallel investigations (repo audit, live Grafana review, ecosystem research, multicloud/architecture challenge)

**Scope caveat — the live half of this review was blocked.** This machine currently has no ogenki Tailscale profile, no `aws-0` kubeconfig context, and the session's Grafana/VM/VL MCP servers point at the Aqemia work tailnet (`*.taileedd2a.ts.net`), not `*.priv.aws.ogenki.io` (which does not resolve from here). Everything below is therefore **as-declared-in-git** plus web research; claims needing live verification are marked ⚠️. How to re-run the live audit is in Appendix C.

---

## 1. TL;DR — what matters most

| # | Finding | Severity | Effort |
|---|---------|----------|--------|
| 1 | **Grafana 13.1.0 is missing the 2026-08-18 security release (CVE-2026-17183, fixed in 13.1.4/13.2.0).** The version is controlled by the vm-k8s-stack's `grafana: 12.7.*` subchart constraint, not Renovate — fix via `grafana.image.tag` values override | High (security) | XS |
| 2 | **Kubernetes events have never reached VictoriaLogs.** `kubernetes-event-exporter` pushes to the *vlcluster* `vlinsert` Service (`:9481`), which doesn't exist — only vlsingle is deployed. Broken since the file was created (2025-08-23), documented as broken in the website docs instead of fixed | High (silent data loss) | XS |
| 3 | **Datasource-plugin supply chain is Renovate-blind in both directions:** VM plugin hardcoded at v0.14.0 (2025-03, ~16 months stale; latest v0.25.2), VL plugin fetched as unpinned GitHub "latest" at *every* Grafana pod start (non-reproducible + external SPOF at boot). Both are signed catalog plugins now — install pinned via the chart `plugins:` list, delete both curl init containers | High | S |
| 4 | **Grafana OnCall estate is dead at every layer.** Upstream archived 2026-03-24 (zero future patches). Repo carries 11 unwired manifests (`observability/base/grafana-oncall/`) *plus live residue in production Grafana*: the `grafana-oncall-app` plugin, a provisioning ConfigMap pointing at nonexistent `oncall-engine:8080`, and 4 seeded secret paths in `scripts/secret-store.sh` | Medium | S |
| 5 | **Retention is incoherent and partly accidental:** metrics **1 day** (`vmsingle`, comment says "for tests only"), logs **unset** (falls to chart/app default, ⚠️ verify effective value live), traces **3 months** — the `retentionPeriod: 3 # 3 days` comment is wrong ×30 (unit-less VictoriaMetrics durations = months). The dashboard-facing signal has the *shortest* retention | Medium | S |
| 6 | **RunLore's 12 health alerts are stranded on aws-0** (`observability/aws-0/.../vmrules/runlore.yaml` is cloud-neutral) while RunLore runs on gcp-0 since #1862 — a dead RunLore on gcp-0 is invisible. Move the VMRule to base | Medium | XS |
| 7 | **Constitution breach: 1 of 9 observability components has a CiliumNetworkPolicy** (runlore only), in the namespace holding Grafana admin creds, the Slack bot token, and the OpenBao CA. No default-deny exists there | Medium (security) | M |
| 8 | **Nothing pages a human and the pipeline has no dead-man's switch.** Alerts end in Slack `#alerts` + RunLore; `Watchdog` is routed to `blackhole`, so a dead alerting pipeline is indistinguishable from a quiet day | Medium | S |
| 9 | **Dashboards in git are freshly cleaned (2026-08-28: #1895/#1897/#1899)** — remaining items are small: dead OnCall plugin, Karpenter dashboard rev-1 needs live metric-name verification ⚠️, orphan `databases` folder, two Flux dashboards tracking a floating `main` branch, possible VL/VT chart-vs-CR dashboard overlap | Low–Medium | S |
| 10 | **Everything Renovate can see is at the latest version** (VM stack 0.91.2, VL 0.13.9, VT 0.1.11, grafana-operator 5.25.0, Vector 0.58, metrics-server 3.14.0, RunLore v0.16.1). All real gaps live in Renovate's blind spots (shell-arg pins, subchart constraints, init-container fetches) | Positive | — |

---

## 2. Inventory — what actually runs (as declared in git)

Both clusters run the same four Flux Kustomizations (`observability-victoria-metrics-k8s-stack` → `observability-grafana-operator` → `observability`, with `observability-victoria-traces` parallel), substituting from `eks-aws-0-vars` / `gke-gcp-0-vars`. Active variants everywhere: **vmsingle + vlsingle** (cluster variants exist as commented-out kustomization entries in *base* — the toggle is repo-wide, not per-cloud).

| Component | Chart / pin | aws-0 | gcp-0 | Freshness (2026-08-29) |
|---|---|---|---|---|
| victoria-metrics-k8s-stack | 0.91.2 → VM v1.150.0, Grafana subchart 12.7.* → app 13.1.0 | ✓ | ✓ | chart latest; **Grafana app 1 security release behind** |
| victoria-logs-single (+ Vector 0.58 subchart) | 0.13.9 → VL v1.52.0 | ✓ | ✓ | latest |
| victoria-traces-single | 0.1.11 → VT ~v0.10.0 | ✓ | ✓ | latest chart; **product is 0.x beta** |
| grafana-operator (external-Grafana mode) | 5.25.0 | ✓ | ✓ | latest |
| kubernetes-event-exporter | Bitnami chart 3.6.3, fork image civitatis 1.8 | ✓ | ✓ | chart 1 patch behind; **upstream dead since 2024-02** |
| metrics-server | 3.14.0 | ✓ | — (GKE managed; removed 2026-08-28 with good rationale) | latest |
| loggen (demo log generator) | 0.1.4 | ✓ | ✓ | demo tool |
| RunLore (SRE agent) | v0.16.1 (git tag + image lockstep) | ✓ | ✓ (overlay: GCPWorkloadIdentity) | latest |
| grafana-oncall | 1.16.5 | **unwired** | **unwired** | upstream archived |

Pipelines in one paragraph each:

- **Metrics:** chart-managed vmagent → vmsingle (10Gi, retention 1d), control-plane scrapes correctly disabled for managed clusters. Scrape CRs: OpenBao (base, both), Karpenter + EC2 node-exporter (aws-0), Cilium×4 + Hubble, Flux controllers + operator, and two LLM-platform scrapes behind the suspended umbrella. No cross-cluster remote-write — each cluster is self-contained.
- **Logs:** Vector (subchart of victoria-logs-single) with a ~490-line bespoke pipeline: CloudNativePG auto_explain **query-plan history** (unit-tested VRL) + catch-all elasticsearch-API sink into vlsingle. kubernetes-event-exporter is supposed to add cluster events (broken — TL;DR #2). vmalert-over-logs (`vmalert-vlsingle.yaml`, ruleSelector `vmlog=true`) works and is demoed by loggen's `LoggenHTTPError500` rule.
- **Traces:** VictoriaTraces queried through the **Jaeger datasource** (upstream-recommended), with three-way trace↔log↔metric correlation already wired (derivedFields, tracesToLogs/Metrics — genuinely ahead of the curve). Producers: Flux notification events (both clusters), one demo app with OTLP+exemplars (aws-0 only), envoy-ai-gateway spans authored but disabled. On gcp-0 VT is near-empty by construction.
- **Alerting:** Alertmanager routes everything (minus `InfoInhibitor|Watchdog|KubeCPUOvercommit` → blackhole) to **RunLore webhook (`continue: true`) + Slack `#alerts`** with Monzo templates and action buttons. `cluster` external labels on vmagent *and* both vmalerts (a documented past incident). VMRules: kube-mixin defaults (control-plane groups off) + OpenBao (7 alerts), Karpenter (3, aws-0), RunLore (12, aws-0 only — TL;DR #6), Flux (3), Cilium (4), loggen demo, LLM SLO/fleet (suspended).

---

## 3. Recent trends & ecosystem updates

**The VictoriaMetrics consolidation bet (ADR-0010) is aging well.** One vendor/operator/chart family now covers all three signals: the k8s-stack chart added `vldistributed` support (0.90–0.91, Aug 2026), VictoriaLogs gained vlagent (first-party log shipper with buffering/replication), VictoriaTraces is integrating into VM Cloud. VM v1.150.0 cut relabeling CPU up to 30%; two LTS lines exist (v1.148.x since Jul 2026, v1.136.x). Downsampling **remains Enterprise-only** — the OSS lever for long retention is stream aggregation, currently unused in this repo.

**Grafana 13** (GrafanaCON, 2026-04-21): Git Sync GA in OSS (bidirectional dashboard↔repo), dynamic dashboards GA (schema v2), observability-as-code toolchain (`grafanactl` + Foundation SDK), Grafana Assistant (Cloud-delivered). **grafonnet is officially deprecated** in favor of the Foundation SDK. Angular plugin support is gone (both installed plugins are React — fine). The `grafana` Helm chart moved to `grafana-community/helm-charts` (old repo support ended 2026-01-30) — one more reason the subchart constraint, not Renovate, controls the deployed Grafana.

**Grafana OnCall OSS:** maintenance mode 2025-03-11 → **repository archived 2026-03-24**. Official migration path is Grafana Cloud IRM (cloud-only). This repo's RunLore + Slack + Alertmanager path already covers the incident story — OnCall lost, but no record says so (ADR gap, §5).

**Bitnami commercialized** (Broadcom, Aug/Sep 2025): free chart/image publication largely stopped (`bitnamilegacy` freeze). This repo's only Bitnami dependency in observability is the kubernetes-event-exporter chart — a dead upstream (resmoio, last release 2024-02) + community fork image + zombie chart channel. Weakest supply chain in the stack.

**Worth watching, not adopting:** Perses v0.54 (CNCF, Red Hat ACM is migrating to it — but no VictoriaMetrics datasource plugins); OpenTelemetry eBPF Instrumentation (OBI, ex-Beyla, beta Apr 2026, 1.0 roadmap — emits OTLP straight into VM/VT, ideal future demo); Grafana Alloy (buys nothing over vmagent+Vector here); Coroot active, Pixie stagnant. SLO tooling: Sloth v0.16 and Pyrra v0.10 both alive, both drop-in via PrometheusRule→VMRule conversion.

---

## 4. Latest features of our tooling (delta vs what we use)

| Tool | We're missing / not using | Worth it? |
|---|---|---|
| VictoriaMetrics | Stream aggregation (OSS pre-aggregation ≈ recording rules at ingestion); deliberate head-vs-LTS choice (Renovate rides head by accident) | Yes if retention grows; LTS choice should be deliberate either way |
| VictoriaLogs | vlagent (first-party shipper alternative to Vector); v1.49–1.52: Splunk HEC ingest, log enrichment, global query filters, UI autocomplete + history | Watch vlagent; features arrive free with Renovate |
| VictoriaTraces | Tempo-API compatibility improving (TraceQL experimental since v0.8); vtagent in v0.11 pre-release | Stay on Jaeger datasource; label VT "beta" in docs |
| Grafana 13 | Git Sync (**skip** — fights grafana-operator for the write path); dynamic dashboards/schema v2; Foundation SDK for authoring custom dashboard JSON | Foundation SDK yes for the 2 large inline dashboards (app-all-in-one 419 lines, runlore 3,056 lines); Git Sync no |
| grafana-operator 5.25 | Dashboard template-variable defaults in CR, scale subresource, declarative public dashboards; mature `GrafanaAlertRuleGroup`/`GrafanaContactPoint` CRDs | Alerting CRDs **no** — would create a second alert pipeline competing with vmalert |
| vm-k8s-stack chart | `vldistributed` management; sync-job dashboard mechanism we already use | Nothing urgent |

---

## 5. Challenging the tooling

**Bets that are holding:**
- **VictoriaMetrics family over Prometheus/Loki/Tempo** — ADR-0010 is a genuinely good record (covers VL and VT with real considered-options). The consolidation is materializing upstream (§3). Hold.
- **vlsingle over vlcluster** — matches upstream guidance verbatim ("prefer single-node whenever one box can carry the load"). Keep, but see the divergence risk below.
- **grafana-operator CR provisioning over Git Sync** — right call; Git Sync assumes Grafana owns the repo write path, the operator assumes Flux owns the Grafana write path. Running both invites reconciliation fights.
- **Vector over OTel Collector** — the hand-built PostgreSQL auto_explain pipeline (with unit tests) would be a regression to rewrite in OTel processors. Keep Vector; add an OTLP-ingest *example* instead so the reference shows both patterns.

**Bets that need a decision or a record:**

| Decision made in code, not on paper | Beat | Repo rule status |
|---|---|---|
| **RunLore as the alerting consumer** | Grafana OnCall — *literally built in this repo and abandoned* | Clearest missing ADR in the stack |
| **Vector as log shipper** | Fluent Bit / Promtail / Alloy | Referenced in ADR-0010 but never decided; carries 490 lines of bespoke VRL |
| grafana-operator CRDs | chart sidecar/file provisioning (still partially configured — a third, empty provisioning channel is live) | Minor ADR or cleanup |
| kubernetes-event-exporter (fork image, Bitnami chart) | Grafana Agent eventhandler / Vector events source | Replace rather than document (§3) |

**Structural risks:**
- **The single/cluster HelmRelease duality has already diverged:** `helmrelease-vlcluster.yaml` has no Vector `customConfig`, so flipping to cluster mode silently drops the PostgreSQL plan-history pipeline the docs present as a headline feature. VM pair: 53 vs 138 lines; VL pair: 536 vs 185. ADR-0010 admits "kept aligned by hand… nothing automated." Extract shared values (`valuesFrom` — the VM stack already proves the pattern) or add a CI diff gate.
- **VictoriaTraces is 0.x beta** running 500m/512Mi + 10Gi on *both* clusters for what is today a demo backend (one instrumented app on aws-0, Flux events, nothing else). Fine as a reference demonstration — but label it beta and consider gcp-0 need.
- **kubernetes-event-exporter** — triple-decker liability (dead upstream + fork image + commercialized chart channel) *and* it's broken (TL;DR #2). Candidate for replacement, not repair.

---

## 6. Issues found (bugs & misconfigurations)

Ranked; file references are exact.

1. **Events → VictoriaLogs broken on both clusters** — `observability/base/kubernetes-event-exporter/helmrelease.yaml:40` targets `victoria-logs-victoria-logs-cluster-vlinsert…:9481` (vlcluster; doesn't exist). Correct vlsingle URL sits commented directly above. Also: `logLevel: debug` + `logFormat: pretty` violates the platform's structured-JSON-logs rule, and `metrics.enabled: false` disables the component's own ServiceMonitor and its only alert. Events currently survive only via Vector re-ingesting the exporter's stdout.
2. **Grafana app version pinned by subchart constraint → security patch lag** — `grafana: 12.7.*` → app 13.1.0; the 2026-08-18 coordinated release (13.1.4/13.2.0, CVE-2026-17183) is not picked up until VictoriaMetrics bumps the dependency. Set `grafana.image.tag` in `vm-common-helm-values-configmap.yaml`.
3. **Plugin init containers** (`vm-common-helm-values-configmap.yaml:276-300`): VM datasource plugin frozen at v0.14.0 (latest v0.25.2); VL datasource plugin fetched as GitHub-API "latest" at every pod start. Replace both with pinned entries in the chart `plugins:` list.
4. **Retention triangle** — vmsingle `retentionPeriod: "1d"` ("Minimal retention, for tests only", `helmrelease-vmsingle.yaml:44`); vlsingle retention unset (⚠️ effective default to verify live; upstream binary default is 7d); vtsingle `retentionPeriod: 3` is **3 months**, not the commented "3 days" (unit-less VictoriaMetrics durations count in months). No `retentionDiskSpaceUsage` cap on 10Gi PVCs.
5. **RunLore VMRule stranded on aws-0** (`observability/aws-0/victoria-metrics-k8s-stack/vmrules/runlore.yaml`) — cloud-neutral file, 12 alerts including `RunloreAgentDown` (`absent(runlore_build_info)`); gcp-0 runs RunLore with zero health alerting. Header also references a nonexistent `./prometheusrule.yaml`.
6. **CNP coverage 1/9** — only runlore has a CiliumNetworkPolicy under `observability/`; no default-deny in the namespace. Constitution says required for every pod-running workload. Documented as a gap in the website docs; still a breach.
7. **Resources unset** on vmsingle, vmagent, vmalert, Alertmanager, Grafana, kube-state-metrics, node-exporter, Vector DaemonSet, event-exporter, and RunLore (×2 replicas) — ADR-0010's "explicitly-set requests and limits" claim is false for vmsingle itself. Explicit floor ≈ 1.6 vCPU / 1.9Gi + ~32Gi PVC per cluster with roughly half the pods unbounded.
8. **Watchdog blackholed** (`vm-common-helm-values-configmap.yaml:86-88`) — no dead-man's switch, no pager. Slack-as-pager is a defensible stance but is nowhere stated.
9. **Vestigial healthCheckExpr** — `clusters/aws-0/observability/observability.yaml` gates on `SQLInstance` Ready; nothing under `observability/aws-0/` renders one (RunLore moved to PVC; the only SQLInstance left is unwired grafana-oncall). gcp-0 comment describes the same phantom database.
10. **Storage-class inconsistency** — vtsingle and runlore use `${storage_class}`; vmsingle and vlsingle omit `storageClassName` and silently take each cluster's default.
11. **Stale docs & comments** — `website/content/docs/platform/observability/_index.md:13` ("runlore stays AWS-only" — false since #1862) and `:57` ("No ADR records the comparison" — ADR-0010 exists, and even says it supersedes that note); `sre-agent.md:89` (identity is EPI-only; gcp-0 uses GCPWorkloadIdentity); the un-deleted "ONE-TIME" prune note in `observability/aws-0/kustomization.yaml:8-17`; `clusters/gcp-0/observability/observability-victoria-traces.yaml:8` ("aws-0 currently does both" — no longer). Candidates for `.doc-claims.yaml` entries rather than one-off fixes.
12. **Floating refs** — Flux dashboards (`flux/observability/grafana-dashboards.yaml`) fetch `refs/heads/main` of flux2-monitoring-example; the VL datasource plugin (item 3). Everything else is pinned.

---

## 7. Multicloud scenarios

**Overall: parity is genuinely good and recently earned** (the 2026-08-26/28 portability wave). Six `${vars}` used by observability manifests; all six defined in both clusters' ConfigMaps; the one AWS-semantic use (`ec2SDConfigs` + `${region}`) is correctly confined to the aws-0 overlay.

**Correct asymmetries (documented, keep):** Karpenter scrape/rules/dashboard aws-0-only; metrics-server absent on GKE (managed, good post-mortem in `observability/gcp-0/kustomization.yaml`); gcp-0 openbao-ca ExternalSecret patch; RunLore gcp overlay (GCPWorkloadIdentity).

**Wrong asymmetries (fix):**
- RunLore VMRule aws-0-only (§6.5).
- aws-0-only `healthCheckExprs` gating on a phantom SQLInstance (§6.9).
- VT Kustomization timeout 10m (aws) vs 5m (gcp) — harmless drift, align anyway.

**Genuinely missing on GCP (not N/A):**
- **GCP OpenBao VM has no host metrics**: AWS startup script installs node-exporter + `ec2SDConfigs` scrape; `opentofu/gcp/openbao/cluster/scripts/` installs nothing and there is no `gceSDConfigs` VMScrapeConfig. GCP OpenBao disk/CPU/memory are unmonitored (its seal/raft metrics *are* scraped on both).
- GKE's managed metrics-server is unscraped (aws-0's has `serviceMonitor.enabled: true`).

**Missing on both clouds:** KEDA exposes Prometheus metrics (`infrastructure/base/keda/helmrelease.yaml:87-91`) but nothing selects them; no DCGM/GPU metrics anywhere despite GPU nodepools on both (LLM platform); GenAI trace export authored but disabled.

**Cross-cluster model — two fully separate panes:** no remote-write, no vmauth federation, no cross-cluster datasources. Operator experience: `grafana.priv.aws.ogenki.io` and `grafana.priv.gcp.ogenki.io`, checked twice; the only shared pane is Slack `#alerts` (with `cluster` external labels making alerts distinguishable). This looks deliberate but is **undocumented and un-ADR'd**. Options for phase 2: (a) document the stance as-is, (b) thin global read layer (vmauth/Grafana with two datasources over Tailscale), (c) full remote-write federation. Note the work-tailnet incident (wiki: Tailscale cert storm) as a caution for any cross-cluster remote-write over cert-gated Tailscale L7 endpoints — machine-to-machine paths prefer L4.

---

## 8. Grafana configuration & dashboard review

**Architecture (sound):** Grafana itself is the vm-k8s-stack subchart deployment; grafana-operator 5.25.0 manages it in **external mode** (`Grafana` CR → `http://victoria-metrics-k8s-stack-grafana`). SSO via Zitadel per cloud (`${identity_provider_url}`, role mapping admin/Editor/Viewer). Datasources: VM (chart sidecar), VL + VT (GrafanaDatasource CRs) with full three-way correlation.

**Dashboard provisioning — three channels live at once:**
1. Chart sync-job → GrafanaDashboard CRs, folder "observability" (~56 expected after the 2026-08-28 cleanup: kube-mixin + dotdc views + VM component dashboards; 8 keys disabled: 5×windows, aix, darwin, node-exporter-full; vmalert + operator explicitly enabled).
2. Operator-managed CRs in git: 7 active (app-all-in-one inline, runlore inline 3,056 lines, node-exporter-full gnet 1860 rev 37, karpenter gnet 20398 rev 1 aws-0-only, VL explorer vendored, VL single gnet 22084 rev 5, VT single gnet 24136 rev 1) + 2 Flux dashboards (floating `main` — §6.12).
3. `grafana.sidecar.dashboards` + `dashboardproviders.yaml` file provider — enabled and **empty**. Dead channel; disable it.

**Already cleaned (2026-08-28, credit where due):** duplicate-UID dotdc `kubernetes-views-*` fight resolved in favor of chart copies (#1895); 7 impossible-OS dashboards disabled (#1899); Karpenter moved out of base (#1897); the one unpinned-`master` fetch removed. The disable-key mechanism fails silently on a typo'd key — worth a validate-doc-claims-style guard if it grows.

**Remaining dashboard items:**

| Verdict | Item | Why |
|---|---|---|
| FIX | `grafana-oncall-app` plugin + `ogenki-grafana-provisioning.yaml` (→ `oncall-engine:8080`, nonexistent) + `accessControlOnCall` toggle | live residue of an archived product |
| VERIFY ⚠️ | `kubernetes-karpenter` (gnet 20398 **rev 1**) | pinned rev likely predates `karpenter_*` metric renames; probe queries first thing on a connected session. Known cardinality gotcha: Karpenter's `operator_*` controller-runtime metrics explode on nodeclaim churn while dashboards only read `karpenter_*` |
| VERIFY-THEN-DELETE | `databases` GrafanaFolder | no in-repo consumer; may be targeted by the SQLInstance composition in `Smana/crossplane-configuration` — check before removing |
| PIN | 2 Flux dashboards (`refs/heads/main`) | floating branch ref; pin to a tag/commit |
| REVIEW | VL single (22084) + VT single (24136) URL-pinned CRs vs the VL/VT charts' own `dashboards.grafanaOperator` output | both mechanisms active → possible duplicates; check live which exist twice ⚠️ |
| DISABLE | empty sidecar/file-provider channel | one provisioning model too many |
| DO | the "ONE-TIME" victoria-traces prune annotation note in `observability/aws-0/kustomization.yaml` | either already done and forgotten, or pending — resolve and delete the note |
| KEEP | chart-bundled set, node-exporter-full, VL explorer/single, VT single, runlore, app-all-in-one (paired with loggen as the demo path) | curated, pinned, folder-organized |

**Live census, drift check, panel-query probes, datasource health, top-queries/cardinality join: not run** (environment mismatch — Appendix C).

---

## 9. Proposals

**Remove (pure wins):**
- OnCall estate, all three layers: `observability/base/grafana-oncall/` (11 files/395 lines incl. RabbitMQ HelmRelease, SQLInstance, KVStore, 4 ExternalSecrets), the Grafana plugin + provisioning residue, secret-store seeds. Pair with the RunLore-over-OnCall ADR.
- The empty sidecar dashboard-provisioning channel.
- Vestigial `healthCheckExprs` (aws-0 observability Kustomization).
- Reconsider loggen scope: 2 replicas × both clouds × ~1.7M synthetic lines/day each, permanently, to demo one logs-alert. Options: keep aws-0 only, or make it a suspended-by-default demo Kustomization.
- Reconsider VT on gcp-0 (near-zero producers) — or accept explicitly as parity-for-reference.

**Fix (small, high value):**
- event-exporter URL (+ `logFormat: json`, `metrics.enabled: true`) — or fold into replacement below.
- `grafana.image.tag` security bump (13.1.4+ / 13.2.0).
- Pin both datasource plugins via `plugins:`; delete init containers.
- Move RunLore VMRule to base; drop the stale prometheusrule reference.
- Deliberate retention: pick real values for vmsingle (1d is "tests only"), vlsingle (currently accidental), vtsingle (fix the ×30 comment), add `retentionDiskSpaceUsage`.
- Pin Flux dashboards; align VT Kustomization timeouts; `${storage_class}` on vmsingle/vlsingle.
- Stale docs (§6.11) + add `.doc-claims.yaml` claims for "runlore runs on both clouds" and "ADR-0010 exists".

**Add (needs design / ADR per repo rules):**
- **CiliumNetworkPolicies for the observability namespace** (constitution compliance) — biggest security-shaped gap.
- **Dead-man's switch**: route `Watchdog` to a heartbeat receiver (healthchecks.io-style or RunLore heartbeat) + a one-paragraph "Slack is the pager" statement — or a real pager decision.
- **SLO example** (Pyrra or Sloth → VMRule burn-rate rules) — cheapest high-value addition for a reference platform; nothing in the repo demonstrates SLOs today. Needs an ADR (Pyrra vs Sloth).
- **Missing ADRs**: RunLore-over-OnCall; Vector-as-shipper; (optional) grafana-operator-over-sidecar; document the two-pane multicloud observability stance.
- **event-exporter replacement** (dead upstream): evaluate Vector-native event collection or a maintained exporter; needs a small ADR.
- **GCP OpenBao host metrics**: node-exporter in the GCE startup script + `gceSDConfigs` VMScrapeConfig (mirror of `ec2.yaml`).
- KEDA scrape (both clouds); DCGM exporter for GPU nodes (LLM platform, when resumed).
- Later/watch: stream aggregation example, OTLP-ingest example app, OBI demo at 1.0, Foundation SDK for the two big inline dashboards, Perses (only if Grafana gravity becomes a problem), vlagent as Vector alternative.

**Decide deliberately (either answer fine, record it):**
- VictoriaMetrics head-vs-LTS (Renovate rides head today by accident).
- Single/cluster duality: extract shared `valuesFrom` or add a CI diff gate; fix vlcluster's missing Vector `customConfig` either way.

---

## 10. Suggested phase-2 work packages

| WP | Scope | Size | Gate |
|---|---|---|---|
| WP1 — Hygiene sweep | TL;DR #1,2,3 fixes + OnCall removal + RunLore rule move + doc/comment staleness + pins | several XS/S PRs | most skip design per repo rules (single-file fixes / config tweaks); OnCall removal PR carries the RunLore ADR |
| WP2 — Retention & sizing policy | deliberate retention triangle, resource requests/limits, storage classes, footprint right-sizing (loggen/VT scope) | S/M | design doc (touches constitution "resources mandatory") |
| WP3 — Observability namespace network policy | default-deny + explicit allows for 9 components | M | design + security review (traffic matrix needed: scrapes, webhooks, Slack egress, GitHub plugin fetch removal helps) |
| WP4 — Alerting reliability | dead-man's switch, pager stance ADR, event-exporter replacement | S/M | ADR |
| WP5 — SLO example | Pyrra-or-Sloth ADR + one worked SLO (e.g. Grafana availability or RunLore pipeline) | M | ADR + design |
| WP6 — GCP parity | OpenBao host metrics on GCE, KEDA scrapes, two-pane stance doc | S/M | design (touches opentofu/gcp) |
| WP7 — Live verification session | run Appendix C: dashboard census, drift, Karpenter probe, VL/VT dup check, cardinality snapshot | S | requires personal tailnet access |

Suggested order: WP1 (unblocks nothing, pure debt) → WP7 (validates ⚠️ items, feeds WP2 numbers) → WP2/WP3/WP4 per appetite → WP5/WP6.

---

## Appendix A — CVE posture

| CVE | Component | Status |
|---|---|---|
| CVE-2026-17183 (fixed 13.1.4/13.2.0, 2026-08-18) | Grafana | **Likely exposed at 13.1.0** — TL;DR #1 |
| CVE-2026-27876/27880 (SQL Expressions RCE, Critical 9.1) | Grafana ≤12.4.1 | Not exposed (13.1.0 postdates; `sqlExpressions` toggle off) |
| CVE-2026-11769 (path traversal) | grafana-operator | Patched (fixed 5.24.0; running 5.25.0) |
| CVE-2026-61625 (vmrestore path traversal) | VictoriaMetrics | Patched (fixed 1.146.0; running 1.150.0) |
| Structural: archived upstreams | OnCall 1.16.5, event-exporter app | No patches will ever come |

## Appendix B — Footprint per cluster (explicit values only)

vlsingle 500m/512Mi + 10Gi · vtsingle 500m/512Mi + 10Gi · vmsingle unset + 10Gi · VL-vmalert 100m/128Mi · grafana-operator 100m/100Mi · metrics-server 2×200m/400Mi (aws only) · loggen 2×200m/200Mi · runlore 2× unset + 2×1Gi · vmagent/Alertmanager/Grafana/KSM/node-exporter/Vector/event-exporter unset. **Explicit floor ≈ 1.6 vCPU / 1.9 Gi + ~32Gi PVC per cluster, with about half the pod population unbounded.** Retention triangle: metrics 1d / logs ~default / traces 3mo.

## Appendix C — Re-running the live audit

Blocked on this machine today: no ogenki Tailscale profile (`tailscale switch --list` shows only `aqemia.com`), no `aws-0` kubeconfig context, `*.priv.aws.ogenki.io` unresolvable, and the session's Grafana/VM/VL MCP servers (user-level `~/.claude.json` + tooling-dev plugin) point at the work tailnet — the project `.mcp.json` declares the correct ogenki VM/VL endpoints but was shadowed. **Side finding: the work Grafana admin password sits in plaintext in `~/.claude.json`.**

To run: connect the personal tailnet profile, `aws eks update-kubeconfig --region eu-west-3 --name aws-0`, use the project `.mcp.json` servers + a Grafana MCP against `grafana.priv.aws.ogenki.io`, then execute: dashboard census & folder listing; `kubectl get grafanadashboards,grafanadatasources,grafanafolders -A` status sweep; panel-query probes for karpenter/node-exporter-full/app-all-in-one/runlore/VL/VT dashboards; datasource health; vmalert rules/alerts state; `top_queries` + `tsdb_status` cardinality snapshot (check `operator_*` Karpenter series); confirm VL/VT chart-vs-CR dashboard duplication; verify effective VL retention.

## Appendix D — Wiki-worthy gotchas surfaced by this review

1. VictoriaMetrics-family charts treat unit-less `retentionPeriod` as **months** — `retentionPeriod: 3 # 3 days` actually keeps 3 months (silent ×30).
2. The vm-k8s-stack's `grafana: 12.7.*` subchart constraint — not Renovate — controls the deployed Grafana app version; security bumps need `grafana.image.tag`. The grafana chart itself moved to `grafana-community/helm-charts`.
3. Both Victoria datasource plugins are installed via curl init containers (one frozen at v0.14.0, one unpinned "latest") — invisible to Renovate.
4. MCP-target gotcha: in a cloud-native-ref session, user-level/plugin MCP servers pointing at the work tailnet shadow the project `.mcp.json`; the dashboard-identity overlap between the two platforms makes auditing the wrong Grafana look plausible.
