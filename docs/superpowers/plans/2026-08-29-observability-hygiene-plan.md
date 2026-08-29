# Observability Hygiene Sweep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved [hygiene design](../specs/2026-08-29-observability-hygiene-design.md): fix the security/supply-chain/bug findings from the observability review, remove the OnCall estate, dedup VL values, add KEDA scraping, write 3 ADRs, and bring all website docs + ADRs up to date.

**Architecture:** GitOps repo — every change is YAML/Markdown; no code compiles. Verification = the repo's static gates (`validate-manifests.sh`, `validate-links.sh`, `validate-doc-claims.sh`) plus helm-render diffs for HelmRelease refactors. No live-cluster claims anywhere.

**Tech Stack:** Flux HelmReleases/Kustomizations, VictoriaMetrics operator CRs, grafana-operator CRs, Helm, yq, difft.

**Ground rules for every task:**
- Work in this worktree (`.claude/worktrees/observability-hygiene`, branch `worktree-observability-hygiene`). Never touch the main checkout.
- Commits: conventional style (`fix(observability): …`), **NEVER add a Co-Authored-By line** (user rule, overrides harness default).
- YAML edits: `yq -i` for structural changes, Edit tool for unique-string replacements.
- After every task: `git status --short` must show only intended files; commit.
- Docs pages carry `lastVerified:` frontmatter — bump it to 2026-08-29 on every page you edit.

---

### Task 1: Grafana security bump + pinned datasource plugins + Renovate coverage

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` (grafana block, lines ~196-304)
- Modify: `.github/renovate.json` (customManagers array)

- [ ] **Step 1: Verify the two plugins exist in the Grafana catalog at the target versions**

Run:
```bash
curl -s https://grafana.com/api/plugins/victoriametrics-metrics-datasource | jq -r '.version'
curl -s https://grafana.com/api/plugins/victoriametrics-logs-datasource | jq -r '.version'
```
Expected: versions ≥ `0.25.2` and ≥ `0.31.0` respectively.
**Decision rule:** pin exactly `0.25.2` / `0.31.0` if the catalog has them; if the catalog's latest is lower (catalog lag), pin the catalog's latest instead and use those numbers everywhere below. If a plugin is missing from the catalog entirely, STOP and raise — do not fall back to the init-container.

- [ ] **Step 2: Edit the grafana block in `vm-common-helm-values-configmap.yaml`**

Replace the `plugins:` list (currently lines 221-223):
```yaml
      plugins:
        - "grafana-oncall-app"
        - "marcusolsson-dynamictext-panel"
```
with (Renovate annotations included — the catalog install string is `<id> <version>`, space-separated, which `grafana cli plugins install` treats as a pinned install):
```yaml
      image:
        # Overrides the grafana subchart's default (13.1.0). The vm-k8s-stack pins
        # `grafana: 12.7.*`, so the Grafana APP version is controlled by that
        # subchart constraint, not by Renovate — security releases (here the
        # 2026-08-18 one) need this explicit tag until the stack bumps its dep.
        tag: "13.1.4"
      plugins:
        # Signed catalog plugins, pinned. These replaced two curl initContainers:
        # one frozen at v0.14.0 for 16 months, one fetching GitHub "latest" at
        # every pod start. Space-separated "<id> <version>" = pinned install.
        # renovate: datasource=github-releases depName=VictoriaMetrics/victoriametrics-datasource extractVersion=^v(?<version>.+)$
        - "victoriametrics-metrics-datasource 0.25.2"
        # renovate: datasource=github-releases depName=VictoriaMetrics/victorialogs-datasource extractVersion=^v(?<version>.+)$
        - "victoriametrics-logs-datasource 0.31.0"
        - "marcusolsson-dynamictext-panel"
```
(`grafana-oncall-app` is deliberately dropped here — Task 2 removes the rest of the OnCall estate.)

- [ ] **Step 3: Delete both `extraInitContainers` entries** (`load-vm-ds-plugin` and `load-vl-ds-plugin`, lines ~261-304 — the whole `extraInitContainers:` key goes away; nothing else uses it).

- [ ] **Step 3b: Disable the empty dashboards sidecar channel** (spec C3 — a third provisioning path that provisions nothing). In the same `grafana:` block: delete the `sidecar.dashboards:` sub-block (KEEP `sidecar.datasources:` — it provisions the VictoriaMetrics datasource), delete the whole `dashboardproviders.yaml:` block, and delete the `dashboards: {}` line. Add a one-line comment where they were: `# dashboards come from grafana-operator CRs and the chart sync-job only — no file-provider sidecar.`

- [ ] **Step 4: Add the Renovate custom manager**

In `.github/renovate.json`, append to `customManagers` (same annotation pattern as the two existing entries):
```json
{
  "description": "Grafana datasource plugin pins inside the vm-common-helm-values ConfigMap. They live in a quoted values.yaml string as '<id> <version>' entries, invisible to the flux/helm-values managers; the VM plugin sat frozen at v0.14.0 for 16 months because of this.",
  "customType": "regex",
  "managerFilePatterns": [
    "/^observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap\\.yaml$/"
  ],
  "matchStrings": [
    "#\\s*renovate:\\s*datasource=(?<datasource>[a-z-]+)\\s+depName=(?<depName>[^\\s]+)\\s+extractVersion=(?<extractVersion>[^\\s]+)[ \\t]*\\r?\\n[ \\t]*-\\s*\"[a-z0-9-]+ (?<currentValue>[0-9]+\\.[0-9]+\\.[0-9]+)\""
  ],
  "versioningTemplate": "semver"
}
```

- [ ] **Step 5: Verify rendering**

Run:
```bash
yq '.data."values.yaml"' observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml | yq '.grafana.plugins, .grafana.image.tag, .grafana.extraInitContainers' -
jq '.customManagers | length' .github/renovate.json
```
Expected: the two pinned plugin strings + dynamictext, `13.1.4`, `null` for extraInitContainers; customManagers length = 3.

- [ ] **Step 6: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml .github/renovate.json
git commit -m "fix(observability): pin Grafana 13.1.4 and both datasource plugins, drop curl initContainers"
```

---

### Task 2: Remove the Grafana OnCall estate (all layers)

**Files:**
- Delete: `observability/base/grafana-oncall/` (11 files)
- Delete: `observability/base/victoria-metrics-k8s-stack/ogenki-grafana-provisioning.yaml`
- Delete: `flux/sources/helmrepo-grafana.yaml`
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` (OnCall residue)
- Modify: `observability/base/victoria-metrics-k8s-stack/kustomization.yaml` (line 28-29)
- Modify: `scripts/secret-store.sh` (OLD_NAMES entries + comments)
- Modify: `observability/aws-0/kustomization.yaml` (comment line 26)

- [ ] **Step 1: Confirm nothing else references what we delete**

Run:
```bash
rg -l "grafana-oncall|oncall" --iglob '!website/**' --iglob '!docs/**' --iglob '!observability/base/grafana-oncall/**' .
rg -U -n "kind: HelmRepository\n\s+name: grafana\b" --iglob '*.yaml' .
```
Expected: hits only in the files this task edits/deletes (plus docs, handled in Task 13). The `grafana` HelmRepository must be consumed only by `observability/base/grafana-oncall/helmrelease-oncall.yaml` — if any other HelmRelease names `sourceRef.name: grafana`, keep `flux/sources/helmrepo-grafana.yaml` and note it in the commit body.

- [ ] **Step 2: Delete the dead directory and files**

```bash
git rm -r observability/base/grafana-oncall/
git rm observability/base/victoria-metrics-k8s-stack/ogenki-grafana-provisioning.yaml
git rm flux/sources/helmrepo-grafana.yaml
```

- [ ] **Step 3: Strip OnCall residue from `vm-common-helm-values-configmap.yaml`**

Three edits:
1. In `grafana.ini → feature_toggles`, delete the line `accessControlOnCall: 'false'` (keep `enable: externalServiceAccounts`).
2. Delete the whole `extraVolumes:` block (its only entry is `plugin-provisioning-oncall`).
3. Delete the whole `extraVolumeMounts:` block (its only entry is the OnCall mount).

- [ ] **Step 4: Remove the kustomization entry**

In `observability/base/victoria-metrics-k8s-stack/kustomization.yaml`, delete:
```yaml
  # Grafana provisioning (Plugins config, RBAC, etc)
  - ogenki-grafana-provisioning.yaml
```

- [ ] **Step 5: Clean `scripts/secret-store.sh`**

Remove the four OLD_NAMES entries `observability/grafana/oncall-{admin,rabbitmq,slackapp,valkey}` and every `oncall` comment block (`rg -n "oncall" scripts/secret-store.sh` must return nothing afterwards; adjust surrounding comments so they still read correctly).

- [ ] **Step 6: Fix the stale comment in `observability/aws-0/kustomization.yaml`**

Line 26: `# (sibling of grafana-oncall); its dashboard + alerts already live here.` → `# its dashboard + alerts already live here.`

- [ ] **Step 7: Verify**

```bash
rg -n "oncall" --iglob '!website/**' --iglob '!docs/**' . || echo CLEAN
yq '.data."values.yaml"' observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml | yq '.grafana.extraVolumes, .grafana.extraVolumeMounts, .grafana."grafana.ini".feature_toggles' -
```
Expected: `CLEAN` (docs handled later); `null`, `null`, and feature_toggles without accessControlOnCall.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore(observability)!: remove the Grafana OnCall estate — upstream archived 2026-03-24, never wired here"
```

---

### Task 3: kubernetes-event-exporter — point events at the VictoriaLogs that exists

**Files:**
- Modify: `observability/base/kubernetes-event-exporter/helmrelease.yaml`

- [ ] **Step 1: Find the fork's watch-error metric name** (needed for the repaired alert)

Run:
```bash
gh api repos/civitatis/kubernetes-event-exporter/contents/pkg/metrics/metrics.go --jq '.content' | base64 -d | rg -n "watch_errors|Name:"
```
**Decision rule:** the alert expr uses `event_exporter_<metric name as registered>` (the release sets `metricsNamePrefix: "event_exporter_"`). If the registered name is `watch_errors`, the series is `event_exporter_watch_errors`; append `_total` only if the source registers it via a promauto counter that Prometheus exposes with `_total`. If the file path differs, locate it with `gh api repos/civitatis/kubernetes-event-exporter/git/trees/master?recursive=1 --jq '.tree[].path' | rg metrics`.

- [ ] **Step 2: Apply the values edits**

In `observability/base/kubernetes-event-exporter/helmrelease.yaml`:

1. `logLevel: debug` → `logLevel: info`; `logFormat: pretty` → `logFormat: json` (platform structured-logs rule).
2. Replace the receiver block (lines ~37-42):
```yaml
        - name: "victorialogs"
          loki:
            # url: "http://victoria-logs-single-server.victoria-logs.svc.cluster.local:9428/insert/loki/api/v1/push"
            url: "http://victoria-logs-victoria-logs-cluster-vlinsert.observability.svc.cluster.local:9481/insert/loki/api/v1/push"
            streamLabels:
              source: kubernetes-event-exporter
```
with:
```yaml
        - name: "victorialogs"
          loki:
            # vlsingle is the deployed variant (see observability/base/victoria-logs/).
            # This URL pointed at the vlcluster vlinsert Service from 2025-08-23 to
            # 2026-08-29 — a Service that never existed here — so direct event push
            # silently went nowhere the whole time.
            url: "http://victoria-logs-victoria-logs-single-server.observability.svc.cluster.local:9428/insert/loki/api/v1/push"
            streamLabels:
              source: kubernetes-event-exporter
```
(Service name verified against the vlsingle Vector sink in `helmrelease-vlsingle.yaml:281` — same Service, non-headless form.)
3. `metrics.enabled: false` → `metrics.enabled: true`.
4. Replace the malformed alert (empty `labels:` + threshold-less expr) with:
```yaml
        groups:
          - name: KubernetesEventExporter
            rules:
              - alert: KubernetesEventExporterWatchErrors
                annotations:
                  message: "kubernetes-event-exporter in {{ `{{` }} $labels.namespace {{ `}}` }} reports watch errors — cluster Events may be missing from VictoriaLogs."
                expr: |
                  sum by (namespace) (rate(<METRIC-FROM-STEP-1>[5m])) > 0
                for: 15m
                labels:
                  severity: warning
```
substituting the metric name established in Step 1. Note in a YAML comment that the VM operator's Prometheus converter turns this PrometheusRule/ServiceMonitor into VM-native objects.

- [ ] **Step 3: Verify**

```bash
yq '.spec.values.config.receivers[1].loki.url, .spec.values.config.logFormat, .spec.values.metrics.enabled' observability/base/kubernetes-event-exporter/helmrelease.yaml
```
Expected: the `victoria-logs-victoria-logs-single-server…:9428` URL, `json`, `true`.

- [ ] **Step 4: Commit**

```bash
git add observability/base/kubernetes-event-exporter/helmrelease.yaml
git commit -m "fix(observability): kubernetes events now reach the VictoriaLogs that exists, with metrics and a working alert"
```

---

### Task 4: Move the RunLore VMRule to base (gcp-0 gets health alerting)

**Files:**
- Move: `observability/aws-0/victoria-metrics-k8s-stack/vmrules/runlore.yaml` → `observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml`
- Modify: both `vmrules/kustomization.yaml` files, `observability/aws-0/victoria-metrics-k8s-stack/kustomization.yaml` (comment)

- [ ] **Step 1: `git mv` the file**

```bash
git mv observability/aws-0/victoria-metrics-k8s-stack/vmrules/runlore.yaml observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml
```

- [ ] **Step 2: Fix the moved file's header**

Delete the stale sentence referring to `./prometheusrule.yaml` (lines 3-6: "This is the VMRule variant… Do not let the two drift" — that sibling file exists only in the upstream RunLore repo). Replace with:
```
# This is the VMRule flavor of RunLore's upstream alerting rules (the upstream
# repo also ships a PrometheusRule variant; only this one is vendored here).
# Cloud-neutral on purpose: runlore runs on BOTH clusters since #1862, so its
# health alerts must too — RunloreAgentDown is absent()-based and only works
# where the workload is expected to exist.
```

- [ ] **Step 3: Update `observability/base/victoria-metrics-k8s-stack/vmrules/kustomization.yaml`**

Add `- runlore.yaml` to resources, and rewrite the comment: keep the karpenter story, replace the runlore paragraph ("runlore's is softer…") with — runlore moved BACK to base on 2026-08-29 because runlore has run on gcp-0 since #1862; parked here it left gcp-0's agent unmonitored.

- [ ] **Step 4: Update the aws-0 side**

Remove `- runlore.yaml` from `observability/aws-0/victoria-metrics-k8s-stack/vmrules/kustomization.yaml`; in `observability/aws-0/victoria-metrics-k8s-stack/kustomization.yaml` remove the `vmrules/runlore.yaml` line from the header comment's file list (karpenter/ec2/vmservicescrape stay). Also in `observability/aws-0/kustomization.yaml`, reword the runlore comment — "its dashboard + alerts already live here" is no longer true (the alerts now live in base): `# RunLore SRE agent — consumes Alertmanager + the observability stack.`

- [ ] **Step 5: Verify both overlays still build**

```bash
kustomize build observability/aws-0/victoria-metrics-k8s-stack/ | yq 'select(.kind == "VMRule") | .metadata.name' -
kustomize build observability/gcp-0/victoria-metrics-k8s-stack/ | yq 'select(.kind == "VMRule") | .metadata.name' -
```
Expected: aws-0 lists `karpenter`, `openbao`, `runlore`; gcp-0 lists `openbao`, `runlore` (no karpenter).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix(observability): runlore health alerts follow runlore to both clusters"
```

---

### Task 5: Deliberate retention + explicit storage classes

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml`
- Modify: `observability/base/victoria-logs/helmrelease-vlsingle.yaml`
- Modify: `observability/base/victoria-traces/helmrelease-vtsingle.yaml`

- [ ] **Step 0: Confirm `${storage_class}` equals each cluster's DEFAULT StorageClass** (the no-op condition for adding `storageClassName` to existing PVCs — the spec's drop-condition):

```bash
rg -n "storage_class" opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf
rg -rn "is-default-class" opentofu/ infrastructure/ | head -5
```
**Decision rule:** if the repo declares gp3 (aws) / standard-rwo (gcp) as the default class (annotation `storageclass.kubernetes.io/is-default-class: "true"` somewhere in the rendered config), OR gp3/standard-rwo are the well-known platform defaults being passed through unchanged, proceed. If `${storage_class}` resolves to something that is NOT the cluster default, adding `storageClassName` would try to mutate immutable PVC fields on reconcile — **drop the storageClassName additions from Steps 2-3** (keep retention changes) and note it in the commit body.

- [ ] **Step 1: Check the vlsingle chart's persistence defaults** (decides whether we may add a PV block safely)

```bash
helm show values victoria-logs-single --repo https://victoriametrics.github.io/helm-charts --version 0.13.9 | yq '.server.persistentVolume' -
```
**Decision rule:** if `enabled: true` and `size: 10Gi` are the defaults, add the explicit block in Step 3 (it renders identically plus storageClassName). If `enabled` defaults to **false**, the live server has no PVC — adding one is a behavior change: still add the block (7d retention needs durable storage and this is the bug), but say so explicitly in the commit body and PR.

- [ ] **Step 2: vmsingle — retention + storage class**

In `helmrelease-vmsingle.yaml` replace:
```yaml
    vmsingle:
      spec:
        retentionPeriod: "1d" # Minimal retention, for tests only
        replicaCount: 1
        storage:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
```
with:
```yaml
    vmsingle:
      spec:
        # Deliberate value (2026-08-29): 14d fits the 10Gi PVC at this fleet size.
        # VictoriaMetrics OSS has no disk-based retention cap — the safety valve is
        # -storage.minFreeDiskSpaceBytes (ingestion pauses, no data loss).
        retentionPeriod: "14d"
        replicaCount: 1
        storage:
          # Same class the admission controller already defaults (gp3 / standard-rwo),
          # stated so the manifest stops depending on each cluster's default.
          storageClassName: ${storage_class}
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
```

- [ ] **Step 3: vlsingle — explicit retention + disk cap + storage class**

In `helmrelease-vlsingle.yaml`, inside `server:` (after `resources:`), add:
```yaml
      # Deliberate values (2026-08-29). Retention was previously unset — whatever
      # the app defaulted to. NOTE the units trap: a unit-less retentionPeriod is
      # MONTHS in VictoriaMetrics charts; always write the suffix.
      retentionPeriod: 7d
      retentionDiskSpaceUsage: 8GiB
      persistentVolume:
        enabled: true
        size: 10Gi
        storageClassName: ${storage_class}
```
(adjust per Step 1's decision rule.)

- [ ] **Step 4: vtsingle — fix the ×30 comment**

In `helmrelease-vtsingle.yaml` replace:
```yaml
      retentionPeriod: 3  # 3 days retention for traces
```
with:
```yaml
      # Unit-less values are MONTHS in VictoriaMetrics charts — the previous
      # `retentionPeriod: 3  # 3 days` actually kept 3 months, ×30 the intent.
      retentionPeriod: 3d
```

- [ ] **Step 5: Verify renders**

```bash
helm template vt victoria-traces-single --repo https://victoriametrics.github.io/helm-charts --version 0.1.11 -n observability -f <(yq '.spec.values' observability/base/victoria-traces/helmrelease-vtsingle.yaml) | rg -- "-retentionPeriod"
```
Expected: `-retentionPeriod=3d`. Repeat the pattern for vlsingle (expect `7d` + `-retention.maxDiskSpaceUsageBytes=8GiB` or the chart's flag name for it — confirm it appears) — note `${storage_class}` breaks raw helm template input; pre-substitute with `sed 's/\${storage_class}/gp3/'`.

- [ ] **Step 6: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml observability/base/victoria-logs/helmrelease-vlsingle.yaml observability/base/victoria-traces/helmrelease-vtsingle.yaml
git commit -m "fix(observability): deliberate retention — metrics 14d, logs 7d capped at 8GiB, traces 3d (was 3 months by unit accident)"
```

---

### Task 6: Wiring hygiene — vestigial healthCheck, stale cluster comments, VT timeout

**Files:**
- Modify: `clusters/aws-0/observability/observability.yaml`
- Modify: `clusters/gcp-0/observability/observability.yaml`
- Modify: `clusters/aws-0/observability/observability-victoria-traces.yaml`
- Modify: `clusters/gcp-0/observability/observability-victoria-traces.yaml`
- Modify: `observability/aws-0/kustomization.yaml`

- [ ] **Step 1: aws-0 `observability.yaml`** — delete the whole `healthCheckExprs:` block (lines 20-24). Nothing under `observability/aws-0/` renders a SQLInstance (runlore uses a PVC; the only SQLInstance in the tree was OnCall's, deleted in Task 2).

- [ ] **Step 2: gcp-0 `observability.yaml`** — replace comment lines 10-12 ("No SQLInstance healthCheckExpr, unlike aws-0's: that one gates on runlore's database…") with:
```
# No healthCheckExprs on either cluster: an earlier aws-0 version gated on a
# SQLInstance that nothing here renders (runlore persists to a PVC, and the
# only SQLInstance ever in this tree belonged to the removed grafana-oncall).
```

- [ ] **Step 3: VT timeout** — in `clusters/aws-0/observability/observability-victoria-traces.yaml` change `timeout: 10m0s` → `timeout: 5m0s` (matches gcp-0; a single small HelmRelease needs nowhere near 10m).

- [ ] **Step 4: gcp-0 VT comment** — in `clusters/gcp-0/observability/observability-victoria-traces.yaml` replace `(aws-0 currently does both; see the note in observability/gcp-0/kustomization.yaml.)` with `(aws-0 did both until 2026-08; both clusters now apply it only here.)`

- [ ] **Step 5: Delete the ONE-TIME note** in `observability/aws-0/kustomization.yaml` (lines 10-18). Rationale for deleting without cluster access: the referenced "first reconcile after this lands" happened weeks ago (the change is on `main`, aws-0 reconciles every 3m); if the prune gap occurred, `observability-victoria-traces` re-created the objects within its 3m interval by design. Keep lines 4-9 (the "deliberately NOT listed" explanation stays true). State this in the commit body.

- [ ] **Step 6: Verify + commit**

```bash
yq '.spec.healthCheckExprs' clusters/aws-0/observability/observability.yaml   # expect null
yq '.spec.timeout' clusters/aws-0/observability/observability-victoria-traces.yaml  # expect 5m0s
git add clusters/ observability/aws-0/kustomization.yaml
git commit -m "chore(observability): drop vestigial SQLInstance healthCheck, align VT timeouts, retire stale one-time notes"
```

---

### Task 7: loggen runs on aws-0 only

**Files:**
- Modify: `observability/gcp-0/kustomization.yaml`
- Modify: `observability/aws-0/kustomization.yaml`

- [ ] **Step 1:** In `observability/gcp-0/kustomization.yaml` delete lines 12-13 (`# Log generator for demo purposes` + `- ../base/loggen`) and add, next to the metrics-server explanation block, the stanza:
```
# ../base/loggen is deliberately NOT listed (2026-08-29). It is a synthetic
# log generator (2 replicas, ~1.7M lines/day) whose only purpose is demoing
# the VictoriaLogs alerting path; the demo lives on aws-0 with the rest of
# the demo app. Nothing on gcp-0 consumed its output.
```
- [ ] **Step 2:** In `observability/aws-0/kustomization.yaml` extend the loggen comment: `# Log generator for demo purposes — aws-0 only, see observability/gcp-0/kustomization.yaml.`
- [ ] **Step 3: Verify + commit**

```bash
kustomize build observability/gcp-0/ | yq 'select(.kind == "HelmRelease") | .metadata.name' - | sort -u
git add observability/gcp-0/kustomization.yaml observability/aws-0/kustomization.yaml
git commit -m "chore(observability): loggen demo generator runs on aws-0 only"
```
Expected before commit: gcp-0 HelmReleases list contains no `loggen`.

---

### Task 8: Pin the Flux dashboards (and record the spec addendum)

**Files:**
- Modify: `flux/observability/grafana-dashboards.yaml`
- Modify: `docs/superpowers/specs/2026-08-29-observability-hygiene-design.md` (C2 list)

- [ ] **Step 1: Resolve the current upstream commit** (re-resolve; do not trust this plan's value blindly):

```bash
gh api repos/fluxcd/flux2-monitoring-example/commits/main --jq '.sha'
```
Expected: a 40-char SHA (was `7ab65dc8b90f7a6751d88f18bbb4e1bee33bf334`, 2026-03-06, at planning time).

- [ ] **Step 2:** In both GrafanaDashboard specs replace `refs/heads/main` in the `url:` with the SHA, and add above each `url:` line:
```yaml
  # Pinned to a commit — refs/heads/main made the dashboard mutate whenever
  # upstream moved, the last unpinned fetch in the repo.
  # renovate: datasource=git-refs depName=https://github.com/fluxcd/flux2-monitoring-example
```
(If a matching Renovate git-refs rule is not straightforward, skip the annotation — the pin is the point; note the skip in the commit body.)

- [ ] **Step 3:** Add one line to the design doc's C2 section: `- flux/observability/grafana-dashboards.yaml: pin the two flux2-monitoring-example dashboard URLs to a commit SHA (last floating refs in the repo).`

- [ ] **Step 4: Verify + commit**

```bash
rg -n "refs/heads/main" flux/ observability/ || echo PINNED
git add flux/observability/grafana-dashboards.yaml docs/superpowers/specs/2026-08-29-observability-hygiene-design.md
git commit -m "fix(observability): pin Flux dashboards to a commit instead of tracking main"
```

---

### Task 9: Scrape KEDA (both clouds)

**Files:**
- Create: `infrastructure/base/keda/vmservicescrape.yaml`
- Modify: `infrastructure/base/keda/kustomization.yaml`

- [ ] **Step 1: Create the scrape file** (Service names/labels/ports verified by rendering chart 2.20.2 at plan time):

```yaml
# KEDA has exposed Prometheus metrics since it was installed
# (prometheus.metricServer.enabled / prometheus.operator.enabled in
# helmrelease.yaml) — but nothing ever scraped them. Both Services expose the
# metrics on a port literally named "metrics" (8080); keda-operator's other
# port (metricsservice, 9666) is the gRPC adapter path, not Prometheus.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: keda-operator
  namespace: keda
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-operator
  endpoints:
    - port: metrics
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: keda-metrics-apiserver
  namespace: keda
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-operator-metrics-apiserver
  endpoints:
    - port: metrics
```

- [ ] **Step 2:** Add `- vmservicescrape.yaml` to `infrastructure/base/keda/kustomization.yaml` resources.

- [ ] **Step 3: Verify + commit**

```bash
kustomize build infrastructure/base/keda/ | yq 'select(.kind == "VMServiceScrape") | .metadata.name' -
git add infrastructure/base/keda/
git commit -m "feat(observability): scrape the KEDA metrics both clusters already expose"
```
Expected: both names print.

---

### Task 10: VL shared values — `vl-common-helm-values` ConfigMap

**Files:**
- Create: `observability/base/victoria-logs/vl-common-helm-values-configmap.yaml`
- Modify: `observability/base/victoria-logs/helmrelease-vlsingle.yaml`
- Modify: `observability/base/victoria-logs/helmrelease-vlcluster.yaml`
- Modify: `observability/base/victoria-logs/kustomization.yaml`

**Background (read first):** `scripts/flux-schema/render-bundle.py` resolves `spec.values` only — never `valuesFrom` (verified: zero matches for `valuesFrom` in the script; the vmsingle HelmRelease documents the same constraint). Consequences: (a) anything Polaris/schema-relevant (securityContext) STAYS in `spec.values` of both variants — only the Vector `customConfig` pipeline moves; (b) the no-regression gate below must merge values the way *Flux* does (valuesFrom first, then spec.values), not the way the validator does.

- [ ] **Step 1: Capture the baseline render** (before any edit):

```bash
git show HEAD:observability/base/victoria-logs/helmrelease-vlsingle.yaml | yq '.spec.values' - | sed 's/\${storage_class}/gp3/' > /tmp/vls-values-before.yaml
helm template victoria-logs victoria-logs-single --repo https://victoriametrics.github.io/helm-charts --version 0.13.9 -n observability -f /tmp/vls-values-before.yaml > /tmp/vls-render-before.yaml
```

- [ ] **Step 2: Create `vl-common-helm-values-configmap.yaml`**

```yaml
# Shared Helm values for BOTH victoria-logs variants (vlsingle active,
# vlcluster on standby). Only the Vector pipeline lives here — it is the block
# that silently diverged: vlcluster shipped with no customConfig at all, so a
# scale-out would have dropped the whole PostgreSQL plan-history pipeline.
#
# What deliberately does NOT live here:
#   - securityContext blocks — scripts/flux-schema/render-bundle.py resolves
#     spec.values only, so Polaris-audited fields must stay inline per variant;
#   - retention — the two charts spell it differently (server.* vs vlstorage.*);
#   - sink endpoints — single-server URLs below are the vlsingle (active)
#     defaults; helmrelease-vlcluster.yaml overrides all three to vlinsert:9481
#     via spec.values deep-merge.
apiVersion: v1
kind: ConfigMap
metadata:
  name: vl-common-helm-values
  namespace: observability
data:
  values.yaml: |
    vector:
      customConfig:
        <THE ENTIRE customConfig BLOCK MOVED VERBATIM FROM helmrelease-vlsingle.yaml
         lines 68-528: sources, transforms, sinks, tests — re-indented under
         data."values.yaml".vector.customConfig; content unchanged, including the
         three single-server sink URIs and all comments>
```
Move, don't retype: `yq '.spec.values.vector.customConfig' observability/base/victoria-logs/helmrelease-vlsingle.yaml` is the source of the block; splice it into the ConfigMap preserving comments by cutting the text region in the editor rather than round-tripping through yq (yq drops comments).

- [ ] **Step 3: Edit `helmrelease-vlsingle.yaml`** — delete the `customConfig:` block from `spec.values.vector` (the `vector:` key keeps `enabled: true` and the `securityContext` with its comment; the big architecture comment above `customConfig` moves to the ConfigMap), and add directly under `spec:` (after `install:`):
```yaml
  valuesFrom:
    - kind: ConfigMap
      name: vl-common-helm-values
      valuesKey: values.yaml
```

- [ ] **Step 4: Edit `helmrelease-vlcluster.yaml`** — add the same `valuesFrom` block, and under `spec.values.vector` (keeping `enabled: true` + securityContext) add:
```yaml
      # The shared pipeline (vl-common-helm-values) defaults its sinks to the
      # vlsingle Service; in cluster mode all ingestion goes through vlinsert.
      customConfig:
        sinks:
          victorialogs_pg_plans:
            uri: http://victoria-logs-victoria-logs-cluster-vlinsert.observability.svc.cluster.local:9481/insert/jsonline
          victorialogs_pg_parse_failures:
            uri: http://victoria-logs-victoria-logs-cluster-vlinsert.observability.svc.cluster.local:9481/insert/jsonline
          vlogs-0:
            endpoints:
              - http://victoria-logs-victoria-logs-cluster-vlinsert.observability.svc.cluster.local:9481/insert/elasticsearch
```

- [ ] **Step 5: List the ConfigMap** in `observability/base/victoria-logs/kustomization.yaml`, above the single/cluster choice (it must be applied whichever variant is active):
```yaml
  # Shared values for BOTH victoria-logs variants below
  - vl-common-helm-values-configmap.yaml
```

- [ ] **Step 6: No-regression gate (vlsingle) + pipeline-presence gate (vlcluster)**

```bash
yq '.data."values.yaml"' observability/base/victoria-logs/vl-common-helm-values-configmap.yaml > /tmp/vl-shared.yaml
yq '.spec.values' observability/base/victoria-logs/helmrelease-vlsingle.yaml | sed 's/\${storage_class}/gp3/' > /tmp/vls-values-inline.yaml
helm template victoria-logs victoria-logs-single --repo https://victoriametrics.github.io/helm-charts --version 0.13.9 -n observability -f /tmp/vl-shared.yaml -f /tmp/vls-values-inline.yaml > /tmp/vls-render-after.yaml
difft --exit-code /tmp/vls-render-before.yaml /tmp/vls-render-after.yaml
```
Expected: **no differences** (Task 5's retention/PV changes are in `HEAD`'s baseline already, so this is a pure refactor).
```bash
yq '.spec.values' observability/base/victoria-logs/helmrelease-vlcluster.yaml > /tmp/vlc-values-inline.yaml
helm template victoria-logs victoria-logs-cluster --repo https://victoriametrics.github.io/helm-charts --version 0.2.8 -n observability -f /tmp/vl-shared.yaml -f /tmp/vlc-values-inline.yaml > /tmp/vlc-render-after.yaml
rg -c "parse_pg_auto_explain" /tmp/vlc-render-after.yaml && rg -c "cluster-vlinsert" /tmp/vlc-render-after.yaml && rg -c "single-server" /tmp/vlc-render-after.yaml || true
```
Expected: `parse_pg_auto_explain` ≥ 1, `cluster-vlinsert` ≥ 3, **`single-server` = 0 in the vector ConfigMap** (the deep-merge must have replaced every endpoint; if `single-server` appears in the rendered vector config, a sink override key is misspelled — fix before committing).
Optional if `vector` is installed: `vector test` the extracted customConfig.

- [ ] **Step 7: Commit**

```bash
git add observability/base/victoria-logs/
git commit -m "refactor(observability): one Vector pipeline for both victoria-logs variants — vlcluster had silently lost it"
```

---

### Task 11: `databases` GrafanaFolder — orphan check

**Files:**
- Possibly delete: `observability/base/grafana-operator/folders/databases.yaml` (+ its kustomization entry)

- [ ] **Step 1: Look for a consumer in the Crossplane configuration** (dashboards rendered by the SQLInstance composition would target folders by name):

```bash
PIN=$(rg -o 'crossplane-configuration.*?:v[0-9.]+' -N infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml | head -1)
gh api "search/code?q=repo:Smana/crossplane-configuration+databases+folderRef" --jq '.items[].path' 2>/dev/null || gh api repos/Smana/crossplane-configuration/git/trees/main?recursive=1 --jq '.tree[].path' | rg -i "grafana|dashboard"
```
Then inspect any hits (`gh api repos/Smana/crossplane-configuration/contents/<path> --jq .content | base64 -d | rg -n "databases|folder"`). Also check this repo: `rg -rn "folderRef|folder:" --iglob '*.yaml' observability/ apps/ infrastructure/ | rg -i database`.

**Decision rule:** any composition or manifest that targets a Grafana folder named `databases` → KEEP the folder and add a comment naming the consumer. Zero hits → delete.

- [ ] **Step 2 (orphan case):**

```bash
git rm observability/base/grafana-operator/folders/databases.yaml
```
Remove its entry from `observability/base/grafana-operator/folders/kustomization.yaml`.

- [ ] **Step 3: Verify + commit**

```bash
kustomize build observability/base/grafana-operator/ | yq 'select(.kind == "GrafanaFolder") | .metadata.name' -
git add -A && git commit -m "chore(observability): drop the databases Grafana folder no dashboard ever targeted"
```
(Adjust message if kept.)

---

### Task 12: ADRs 0029, 0030, 0031 + ADR-0010 correction

**Files:**
- Create: `website/content/docs/decisions/0029-runlore-over-grafana-oncall.md`
- Create: `website/content/docs/decisions/0030-vector-as-log-shipper.md`
- Create: `website/content/docs/decisions/0031-per-cluster-observability-panes.md`
- Modify: `website/content/docs/decisions/0010-victoriametrics-over-prometheus.md`

- [ ] **Step 1:** Read `website/content/docs/decisions/template.md` and two recent ADRs (0024, 0027) to match structure/frontmatter exactly (status, date, decision-makers fields, Considered Options / Decision Outcome sections).

- [ ] **Step 2: Write ADR-0029 — "RunLore + Slack over Grafana OnCall"**. Substance to include: OnCall built fully in-repo (engine+RabbitMQ+SQLInstance+KVStore, chart 1.16.5) but never wired; upstream maintenance-mode 2025-03-11, archived 2026-03-24, no future security patches, migration path is Grafana Cloud IRM (cloud-only); the chosen path — Alertmanager → RunLore webhook (auto-investigation) + Slack `#alerts` — was already carrying the whole incident flow; OnCall would add ~5 standing workloads for a one-operator platform. Consequences: the estate was deleted (this branch); paging/dead-man's-switch remains a named gap (see ADR-0031).

- [ ] **Step 3: Write ADR-0030 — "Vector as the log shipper"** (backfill; say so in the status/context). Considered: Fluent Bit (lighter, but VRL and native unit tests carried the PostgreSQL auto_explain plan-history pipeline — ~490 lines with in-repo tests), Promtail (Loki-shaped, deprecated upstream), OTel Collector (heavier config model, no VRL; an OTLP-ingest *example* remains desirable separately). Chosen: Vector as the victoria-logs chart's subchart, one DaemonSet per cluster. Note vlagent (VictoriaMetrics' own shipper) as the watched successor candidate.

- [ ] **Step 4: Write ADR-0031 — "Per-cluster observability panes; Slack + RunLore as the pager"**. Records: each cluster keeps its full stack + own Grafana; no remote-write federation / no vmauth global pane (cost, and remote-write over cert-gated Tailscale L7 endpoints is a stampede risk — reference the cert-storm incident pattern); the shared pane is Slack `#alerts` with the `cluster` external label on both vmalerts; Watchdog stays routed to `blackhole` — accepted consequence: a dead alerting pipeline is silent; a real dead-man's switch (external heartbeat) is the named follow-up.

- [ ] **Step 5: Correct ADR-0010** — locate the "explicitly-set CPU/memory requests and limits" claim (`rg -n "requests and limits" website/content/docs/decisions/0010-victoriametrics-over-prometheus.md`) and reword to what is true: resources are explicit on VictoriaLogs/VictoriaTraces servers, the VL vmalert and grafana-operator; vmsingle/vmagent/Alertmanager/Grafana run on chart defaults today, right-sizing deferred until live usage data exists. Also update its single/cluster "kept aligned by hand… nothing automated" sentence to mention the shared `vl-common-helm-values` ConfigMap from Task 10.

- [ ] **Step 6:** Add the three ADRs to the decisions `_index.md` listing if that page enumerates them (check `rg -n "0028" website/content/docs/decisions/_index.md`).

- [ ] **Step 7: Verify + commit**

```bash
./scripts/validate-links.sh
git add website/content/docs/decisions/
git commit -m "docs(adr): record RunLore-over-OnCall, Vector-as-shipper, and the two-pane observability stance"
```

---

### Task 13: Docs — update everything this branch changed

**Files (grep-verify the full list first):**
- Modify: `website/content/docs/platform/observability/_index.md`
- Modify: `website/content/docs/platform/observability/dashboards-and-alerts.md`
- Modify: `website/content/docs/platform/observability/logs.md`
- Modify: `website/content/docs/platform/observability/metrics.md`
- Modify: `website/content/docs/platform/observability/sre-agent.md`

- [ ] **Step 1: Enumerate every affected mention**

```bash
rg -n "oncall|OnCall" website/content/docs/ | rg -v decisions
rg -n '"1d"|Minimal retention|tests only|retentionPeriod' website/content/docs/
rg -n "nine component|eight are wired|seven of the eight|AWS-only" website/content/docs/platform/observability/
rg -n "loggen" website/content/docs/ | rg -v decisions
rg -n "load-vl-ds-plugin|load-vm-ds-plugin|initContainer|v0.14.0|latest" website/content/docs/platform/observability/dashboards-and-alerts.md
rg -n "No ADR in this repository records" website/content/docs/
```

- [ ] **Step 2: `_index.md`** — rewrite the opening: eight component directories, all wired (grafana-oncall removed 2026-08-29 → ADR-0029); runlore runs on BOTH clusters (EKS Pod Identity on aws-0, GCPWorkloadIdentity on gcp-0); drop `grafana-oncall` from the component table; replace "No ADR in this repository records the comparison…" with a link to ADR-0010; update the retention sentence (single-node VictoriaMetrics now `14d`, VictoriaLogs `7d` capped, deliberate values with a pointer to the units trap); note loggen is aws-0-only; update the frontmatter `description:` (it currently advertises "why one of nine component directories never actually deploys") and `lastVerified: 2026-08-29`.

- [ ] **Step 3: `dashboards-and-alerts.md`** — replace the whole "Grafana OnCall: built but not deployed" section (lines ~186-247) with a short "Grafana OnCall (removed)" note pointing at ADR-0029. Do NOT keep the old heading text as an alias — the `oncall-removed` doc-claim (Task 14) forbids the phrase "built but not deployed" on this page; update the two inbound relrefs from `_index.md` to the new anchor (`./scripts/validate-links.sh` catches misses); describe the new plugin install mechanism (pinned catalog plugins via `plugins:`, no initContainers); update the components list at ~line 241; update any CNP-gap sentence that enumerates grafana-oncall.

- [ ] **Step 4: `logs.md`** — rewrite the kubernetes-event-exporter section (lines ~59-81): events now push directly to the vlsingle loki endpoint (the year-long vlcluster-URL breakage is worth one honest sentence + the fix date), metrics enabled, alert repaired; loggen marked aws-0-only; document vlsingle retention 7d/8GiB cap; describe the shared `vl-common-helm-values` ConfigMap and why sink endpoints are per-variant.

- [ ] **Step 5: `metrics.md`** — update any `1d` retention mention to `14d` with the "deliberate value" framing; add one sentence that KEDA metrics are now scraped (VMServiceScrape in `infrastructure/base/keda/`).

- [ ] **Step 6: `sre-agent.md`** — line ~89 identity table: EKS Pod Identity on aws-0, `GCPWorkloadIdentity` on gcp-0 (see `observability/gcp-0/runlore/workloadidentity.yaml`); add that RunLore's 12 health alerts now apply on both clusters (base VMRule).

- [ ] **Step 7: Verify + commit**

```bash
./scripts/validate-links.sh
rg -n "oncall" website/content/docs/platform/ | rg -vi "removed|ADR-0029|0029" || echo CLEAN
git add website/content/docs/platform/
git commit -m "docs(observability): pages match the stack again — OnCall gone, retention deliberate, runlore everywhere, events flowing"
```

---

### Task 14: `.doc-claims.yaml` guards for the new load-bearing claims

**Files:**
- Modify: `.doc-claims.yaml`

- [ ] **Step 1:** Append these entries (mirror the existing schema exactly; tune `source.pattern`/`must_contain` until `validate-doc-claims.sh` passes and a deliberate mutation fails):

```yaml
  - id: vmsingle-retention
    why: >-
      Metrics retention was "1d — for tests only" for the repo's whole life while
      docs discussed look-back windows. The value is now deliberate; docs must
      quote the real one.
    source:
      file: observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml
      pattern: 'retentionPeriod:\s*"(\d+d)"'
    pages:
      - website/content/docs/platform/observability/_index.md
      - website/content/docs/platform/observability/metrics.md
    must_contain: '{value}'

  - id: vlsingle-retention
    why: >-
      VictoriaLogs retention was unset (app default) — invisible in git. Now
      explicit; the logs page must state it.
    source:
      file: observability/base/victoria-logs/helmrelease-vlsingle.yaml
      pattern: 'retentionPeriod:\s*(\d+d)'
    pages:
      - website/content/docs/platform/observability/logs.md
    must_contain: '{value}'

  - id: vtsingle-retention-has-unit
    why: >-
      Unit-less retentionPeriod is MONTHS in VictoriaMetrics charts — a bare
      `3` kept 3 months while its own comment said 3 days. The suffix is the
      guard: this fails if anyone strips it back to a bare number.
    source:
      file: observability/base/victoria-traces/helmrelease-vtsingle.yaml
      pattern: 'retentionPeriod:\s*(\d+d)'
    pages:
      - website/content/docs/platform/observability/dashboards-and-alerts.md
    must_contain: '{value}'

  - id: grafana-plugin-pins
    why: >-
      The datasource plugins were installed by curl initContainers — one frozen
      16 months, one unpinned "latest" — invisible to Renovate. The pinned
      version is now the docs' claim too.
    source:
      file: observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml
      pattern: 'victoriametrics-logs-datasource (\d+\.\d+\.\d+)'
    pages:
      - website/content/docs/platform/observability/dashboards-and-alerts.md
    must_contain: '{value}'

  - id: loggen-aws-only
    why: >-
      loggen writes ~1.7M synthetic lines/day; it was silently running on both
      clouds. gcp-0's kustomization must keep the explicit exclusion stanza and
      the logs page must say where the demo actually runs.
    source:
      file: observability/gcp-0/kustomization.yaml
      pattern: '\.\./base/(loggen) is deliberately NOT listed'
    pages:
      - website/content/docs/platform/observability/logs.md
    must_contain: 'aws-0 only'

  - id: oncall-removed
    why: >-
      The OnCall estate (archived upstream) was removed on 2026-08-29 with
      ADR-0029 recording why. Docs must not resurrect the "built but not
      deployed" story, and the ADR must keep existing.
    source:
      file: website/content/docs/decisions/0029-runlore-over-grafana-oncall.md
    pages:
      - website/content/docs/platform/observability/_index.md
      - website/content/docs/platform/observability/dashboards-and-alerts.md
    must_not_contain: 'built but not deployed|never actually deploys'

  - id: runlore-alerts-both-clouds
    why: >-
      runlore's 12 health alerts sat in the aws-0 overlay for months after
      runlore itself reached gcp-0 — a dead agent there was invisible. The rule
      file must stay in base, and the SRE-agent page must not resurrect the
      AWS-only story.
    source:
      file: observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml
    pages:
      - website/content/docs/platform/observability/sre-agent.md
    must_not_contain: 'AWS-only|aws-0 only|stays AWS'
```

- [ ] **Step 2: Verify both directions**

```bash
./scripts/validate-doc-claims.sh; echo "exit=$?"
sed -i '' 's/retentionPeriod: "14d"/retentionPeriod: "99d"/' observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml && ./scripts/validate-doc-claims.sh; echo "mutation exit=$? (expect nonzero)"; git checkout -- observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml
```
Expected: exit 0, then nonzero on the mutation, then restored.

- [ ] **Step 3: Commit**

```bash
git add .doc-claims.yaml
git commit -m "docs: pin the new observability claims — retention values, plugin pins, runlore-everywhere"
```

---

### Task 15: Full docs + ADR audit (fan-out), then fix everything found

**Files:** read-only sweep over `website/content/docs/**`, `docs/*.md`, `README.md`; fixes land wherever findings point.

- [ ] **Step 1 (coordinator): dispatch 5 parallel READ-ONLY audit agents.** Each prompt: "Audit these pages of /…/cloud-native-ref (worktree path) for claims contradicted by the repo's manifests/opentofu/scripts as of this branch. For every checkable factual claim (a path, a version, a count, a component name, a behavior), verify against the source files. Return findings ONLY as a list: `page:line — claim — contradicting evidence file:line — proposed one-line fix`. Ignore style. No file writes." Scopes:
  1. `website/content/docs/platform/**` (34 pages — the branch's own changes are fresh, catch ripple effects)
  2. `website/content/docs/decisions/**` (all ADRs: status accuracy, superseded-by links, claims vs current manifests)
  3. `website/content/docs/get-started/**` (12)
  4. `website/content/docs/{reference,guides,concepts}/**` (20)
  5. `docs/*.md` top level (`gcp-bootstrap.md`, `platform-constitution.md`, `docs/architecture/`) + `README.md`
- [ ] **Step 2 (coordinator): triage findings.** Discard anything speculative or already handled by Tasks 12-14. For each confirmed finding, apply the fix; bump `lastVerified` on touched pages.
- [ ] **Step 3: Verify + commit (one or few `docs:` commits, grouped by section)**

```bash
./scripts/validate-links.sh && ./scripts/validate-doc-claims.sh
git add website/ docs/ README.md 2>/dev/null; git commit -m "docs: full docs+ADR audit — fix every claim the manifests contradict"
```

---

### Task 16: Full verification suite + branch wrap-up

- [ ] **Step 1: The evidence table, fresh**

```bash
./scripts/validate-manifests.sh          # expect exit 0, report shows Invalid: 0, Skipped: 0
./scripts/validate-links.sh              # expect exit 0
./scripts/validate-doc-claims.sh         # expect exit 0
python3 scripts/flux-schema/test-check-substitution.py  # expect pass
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .   # expect exit 0
```
Quote each command's tail output — do not paraphrase. If `validate-manifests.sh` fails on anything this branch touched, fix forward within the responsible task's scope; if it fails on something pre-existing and unrelated, record it verbatim for the PR body's "Note for reviewers".

- [ ] **Step 2: Re-render the two spot-gates** (they may have drifted across tasks): the VL no-regression diff (Task 10 Step 6) and the vtsingle `-retentionPeriod=3d` render (Task 5 Step 5).

- [ ] **Step 3: Review the branch as a whole**

```bash
git log --oneline origin/main..HEAD
git diff origin/main --stat
```
Expected: ~13-16 commits, each single-theme; diff touches only `observability/`, `clusters/*/observability/`, `infrastructure/base/keda/`, `flux/`, `scripts/secret-store.sh`, `.github/renovate.json`, `.doc-claims.yaml`, `website/`, `docs/`.

- [ ] **Step 4: STOP — do not push, do not open a PR.** Hand back to the coordinator: the superpowers finishing flow (`superpowers:finishing-a-development-branch`) decides merge/PR with the user. The PR body must follow the user's global PR-description format (before→after values first, "why it costs nothing / why it helps" split for the removals, test plan quoting the gate outputs, and a "what this PR does not do" section naming the deferred work: CNPs, SLO example, event-exporter replacement, GCP OpenBao host metrics, resource right-sizing, dead-man's switch, live verification items).

---

## Post-merge follow-ups (NOT in this plan)

`/verify-spec` against the live clusters once the personal tailnet is reachable: vmsingle disk headroom at 14d, events arriving in VictoriaLogs (`{source="kubernetes-event-exporter"}`), plugin versions in the Grafana UI, Karpenter dashboard rev-1 metric-name probe, VL/VT chart-vs-CR dashboard duplication, effective VL retention flags.
