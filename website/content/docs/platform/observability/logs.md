---
title: Logs
weight: 20
description: VictoriaLogs and Vector, kubernetes-event-exporter, loggen, and the LogsQL syntax rules that are easy to get wrong.
lastVerified: 2026-08-20
---

## VictoriaLogs

`observability/base/victoria-logs/` follows the same single/cluster split as
the metrics stack: `helmrelease-vlsingle.yaml` (chart `victoria-logs-single`
0.13.9) is active; `helmrelease-vlcluster.yaml` (chart `victoria-logs-cluster`
0.2.8 — 3 replicas, 7d retention, `retentionDiskSpaceUsage: "9GiB"`, HPA
2→10 on `vlselect`/`vlinsert`) is present but commented out of
`kustomization.yaml`. No `retentionPeriod` is set on the active vlsingle
release — it runs on the chart's default, not a value pinned in this repo.

**The log shipper is Vector**, not Fluent Bit or Promtail — confirmed by the
`vector:` block in `helmrelease-vlsingle.yaml`. (An older draft of this
documentation claimed Fluent Bit; that was never true of this repo and has
been dropped rather than carried forward.)

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
and routes every event to two receivers simultaneously: `dump` (writes to
`/dev/stdout`) and `victorialogs` (Loki-push API).

{{< callout type="warning" >}}
The `victorialogs` receiver's URL targets the **cluster-mode** VictoriaLogs
service — `victoria-logs-victoria-logs-cluster-vlinsert.observability.svc.cluster.local:9481`
(`observability/base/kubernetes-event-exporter/helmrelease.yaml`). Only
vlsingle is actually deployed (see above), whose real service is
`victoria-logs-victoria-logs-single-server` on port 9428. This mismatch is
verified against the manifests, not a guess — events most likely reach
`stdout` via the `dump` receiver but do **not** reach VictoriaLogs through
this path. Treat "Kubernetes events are queryable in VictoriaLogs" as false
until this URL is fixed or vlcluster is enabled.
{{< /callout >}}

Also worth knowing: `metrics.enabled: false` in the same HelmRelease wraps a
`serviceMonitor.enabled: true` and a `prometheusRule.enabled: true` — a
scrape and an alert are configured against a metrics endpoint the chart's
own top-level toggle disables. Image is overridden to
`ghcr.io/civitatis/kubernetes-event-exporter:1.8`, a community fork, not the
Bitnami-published image the chart normally pulls.

## loggen

A synthetic log generator (`observability/base/loggen/`) — two replicas
producing JSON logs at roughly 10/s with a 10% synthetic error rate
(`--sleep 0.1 --error-rate 0.1 --format json --latency 0.2`). It exists to
exercise the log pipeline and dashboards with predictable traffic, not to
represent a real workload.

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
