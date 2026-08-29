---
title: Logs
weight: 20
description: VictoriaLogs and Vector, kubernetes-event-exporter, loggen, and the LogsQL syntax rules that are easy to get wrong.
lastVerified: 2026-08-30
---

## VictoriaLogs

`observability/base/victoria-logs/` follows the same single/cluster split as
the metrics stack: `helmrelease-vlsingle.yaml` (chart `victoria-logs-single`
0.13.9) is active; `helmrelease-vlcluster.yaml` (chart `victoria-logs-cluster`
0.2.8 — 3 replicas, HPA 2→10 on `vlselect`/`vlinsert`) is present but
commented out of `kustomization.yaml`. Retention is explicit on both variants
as of 2026-08-30: `retentionPeriod: 7d`, capped by `retentionDiskSpaceUsage`
(`8GiB` on the active vlsingle, whose PVC is 10Gi; `9GiB` on the standby
vlcluster) — before that, the active release ran on whatever the app
defaulted to, with no value pinned in this repo. Always write the unit
suffix: a unit-less `retentionPeriod` means **months** in the
VictoriaMetrics chart family.

**The log shipper is Vector**, not Fluent Bit or Promtail —
[ADR-0030]({{< relref "/docs/decisions/0030-vector-as-log-shipper.md" >}})
records the choice. (An older draft of this documentation claimed Fluent
Bit; that was never true of this repo and has been dropped rather than
carried forward.)

### One Vector pipeline, shared between both variants

The Vector pipeline — sources, transforms, the PostgreSQL plan-history sinks
and their unit tests — lives in the `vl-common-helm-values` ConfigMap
(`observability/base/victoria-logs/vl-common-helm-values-configmap.yaml`) and
is applied to **both** HelmReleases via `valuesFrom`. It is shared since
2026-08-30 because the vlcluster variant had silently shipped with no
`customConfig` at all: a scale-out would have dropped the whole PostgreSQL
plan-history pipeline without any diff saying so.

Three things deliberately stay inline per variant:

- **`securityContext` blocks** — the manifest-validation renderer resolves
  `spec.values` only, so Polaris-audited fields must not move into a
  ConfigMap.
- **Retention** — the two charts spell it under different keys
  (`server.*` vs `vlstorage.*`).
- **The general catch-all sink** — it is chart-specific. The single chart's
  generated sink is named `vlogs-0` and is overridden inline in
  `helmrelease-vlsingle.yaml` (to add the `VL-*` headers); the cluster chart
  ships its own `vlogs` sink already pointed at `vlinsert`. A shared copy
  would double every general log line in cluster mode.

The shared PG sinks carry the vlsingle (active) URIs;
`helmrelease-vlcluster.yaml` overrides both to `vlinsert:9481` by
`spec.values` deep-merge.

## LogsQL syntax rules

These are correct and non-obvious enough that getting them wrong produces
queries that silently return nothing, not an error:

1. **Kubernetes labels use dot notation, not underscores.** `kubernetes.container_name`,
   `kubernetes.pod_namespace`, `kubernetes.pod_name` — never `kubernetes_container_name`.
   Confirmed directly in Vector's own sink config:
   ```yaml
   # observability/base/victoria-logs/helmrelease-vlsingle.yaml
   VL-Stream-Fields: stream,kubernetes.pod_name,kubernetes.container_name,kubernetes.pod_namespace
   ```
2. **After `| unpack_json`, fields are prefixed `log.`** — `log.level`,
   `log.trace_id`, not the bare field name. Confirmed by the trace-correlation
   derived field on the Grafana datasource:
   ```yaml
   # observability/base/victoria-logs/grafana-datasource.yaml
   matcherRegex: "\"log\\.trace_id\":\"([0-9a-f]+)\""
   ```
3. **Grafana dashboard JSON needs `$${var}` (double dollar), not `${var}`,**
   to survive Flux `postBuild` substitution — Flux collapses `$${` to `${`
   at render time, so a single `$` gets eaten before Grafana ever sees the
   variable. Confirmed in the same datasource file:
   ```yaml
   url: "$${__value.raw}"
   ```
   and in VictoriaTraces' datasource (`tracesToMetrics` queries use
   `rate(http_server_requests_total{$$__tags}[5m])`).

**Worked example**, combining rules 1 and 2:

```logsql
{kubernetes.container_name="myapp"} | unpack_json | log.level:error | limit 10
{kubernetes.pod_namespace="apps"} | limit 10
```

## kubernetes-event-exporter

Watches Kubernetes Events cluster-wide (`clusterName: "${cluster_name}"` tag)
and pushes every event to the deployed vlsingle's Loki-compatible endpoint —
`victoria-logs-victoria-logs-single-server` on port 9428
(`observability/base/kubernetes-event-exporter/helmrelease.yaml`). That is
the **only** path events take, and it works as of 2026-08-29.

Both halves of that sentence earn their date. From 2025-08-23 to 2026-08-29
the receiver URL pointed at the **vlcluster** `vlinsert` Service — a Service
that has never been deployed here — so the direct push silently went nowhere
for a year; events only turned up in VictoriaLogs by accident, because a
second receiver (`dump`) wrote them to `/dev/stdout` and Vector re-ingested
the container log. The `dump` receiver is now deleted too: under the fork's
file sink it rendered every event as a contentless `{}` noise line, and it
was never a fallback (if the informer stops, no receiver gets anything). The
exporter's own operational logs are structured now as well
(`logFormat: json`, `logLevel: info`).

Its metrics are real for the first time: `metrics.enabled: true` — it was
`false`, silently discarding the `serviceMonitor.enabled: true` and
`prometheusRule.enabled: true` nested under it — with a `ServiceMonitor` in
`observability` and one repaired alert, `KubernetesEventExporterWatchErrors`
(`severity: warning`, sustained `rate > 0` for 15m). The alert's message
deliberately names no namespace: the fork registers `WatchErrors` as a
labelless counter, so the previous per-namespace grouping could never have
matched anything. Image stays overridden to
`ghcr.io/civitatis/kubernetes-event-exporter:1.8`, a community fork, not the
Bitnami-published image the chart normally pulls.

## loggen

A synthetic log generator (`observability/base/loggen/`) — two replicas
producing JSON logs at roughly 10/s with a 10% synthetic error rate
(`--sleep 0.1 --error-rate 0.1 --format json --latency 0.2`). It exists to
exercise the log pipeline and dashboards with predictable traffic, not to
represent a real workload — which is why it is applied on `aws-0` only:
`observability/gcp-0/kustomization.yaml` deliberately skips it, since
nothing on `gcp-0` consumed its ~1.7M lines/day.

### Alerting on logs

`loggen` ships the one real, deployed example of a **LogsQL-flavored**
`VMRule` in this repo — `type: vlogs` instead of the implicit PromQL type,
demonstrating both syntax rules above in a single `expr`:

```yaml
# observability/base/loggen/demo-vmrule.yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: loggen
  labels:
    vmlog: "true"
spec:
  groups:
    - name: loggen
      type: vlogs
      rules:
        - alert: LoggenHTTPError500
          expr: 'kubernetes.pod_labels.app.kubernetes.io/instance:"loggen" AND log.status:"5"* | stats by (kubernetes.pod_name) count() as server_errors | filter server_errors:>100'
```

The `vmlog: "true"` label is what makes this rule visible to
`victoria-logs`'s own `VMAlert` (`vmalert-vlsingle.yaml`), whose
`ruleSelector.matchLabels` is scoped to exactly that label — VictoriaMetrics'
default `VMAlert` (evaluating PromQL rules against `vmsingle`) never sees it.
