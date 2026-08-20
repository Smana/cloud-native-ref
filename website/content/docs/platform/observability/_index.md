---
title: Observability
weight: 40
description: VictoriaMetrics, VictoriaLogs, and VictoriaTraces under one Grafana, the SRE agent that reacts to their alerts, and why one of nine component directories never actually deploys.
lastVerified: 2026-08-20
---

`observability/base/` holds nine component directories. **Eight are wired
into Flux; one is not.** `grafana-oncall` is a fully-built HelmRelease pair
(engine + RabbitMQ, external Postgres and Valkey already provisioned) that no
`Kustomization` anywhere in `clusters/` or `flux/` ever references — it does
not run on the cluster today. Every other component below does. See
[Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md#grafana-oncall-built-but-not-deployed" >}})
for what that means in practice.

| Component | Deployed via | Documented in |
|---|---|---|
| `victoria-metrics-k8s-stack` | `observability-victoria-metrics-k8s-stack` Kustomization | [Metrics]({{< relref "/docs/platform/observability/metrics.md" >}}) |
| `metrics-server` | `observability` Kustomization | [Metrics]({{< relref "/docs/platform/observability/metrics.md" >}}) |
| `victoria-logs` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `kubernetes-event-exporter` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `loggen` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `victoria-traces` | `observability-victoria-traces` Kustomization | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}) |
| `grafana-operator` | `observability-grafana-operator` Kustomization | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}) |
| `runlore` | `observability` Kustomization | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}) |
| `grafana-oncall` | **not referenced anywhere** | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md#grafana-oncall-built-but-not-deployed" >}}) |

CloudNativePG's own metrics, logs, backups, and dashboards are covered
separately in [PostgreSQL]({{< relref "/docs/platform/observability/postgresql.md" >}}):
that component lives under `infrastructure/base/cloudnative-pg*/`, not
`observability/base/`, but it feeds the same VictoriaMetrics/VictoriaLogs
stores and the same Grafana.

## Why VictoriaMetrics and VictoriaLogs

Both are PromQL/LogsQL-compatible, single-binary-first alternatives to
Prometheus and Loki — existing dashboards and alerting rules written against
either wire protocol work unchanged, so adopting them cost nothing on that
front. The two products share one operator
(`operator.victoriametrics.com/v1beta1` — `VMRule`, `VMServiceScrape`,
`VMScrapeConfig`, `VMAlert`) and one Grafana, which is what lets a single
`VMAlert` evaluate both PromQL rules against VictoriaMetrics and LogsQL rules
(`type: vlogs`) against VictoriaLogs from the same `ruleSelector` mechanism —
see [`loggen`'s alert]({{< relref "/docs/platform/observability/logs.md#alerting-on-logs" >}})
for a concrete `type: vlogs` example. No ADR in this repository records the
comparison against Prometheus/Loki directly; treat this section as the
current rationale, not a linked decision record.

## Single mode today, cluster mode standing by

Both VictoriaMetrics and VictoriaLogs ship **two** HelmReleases in their
component directories — `helmrelease-vmsingle.yaml`/`helmrelease-vlsingle.yaml`
(active) and `helmrelease-vmcluster.yaml`/`helmrelease-vlcluster.yaml`
(present on disk, commented out of the `Kustomization`). The cluster charts
are pre-configured (replication factor 2, HPA 2→10 on `vlselect`/`vlinsert`,
zone-aware anti-affinity) but nothing currently runs them — this cluster
runs single-node VictoriaMetrics (`retentionPeriod: "1d"`, explicitly
commented "Minimal retention, for tests only") and single-node VictoriaLogs.
Scale-out is a matter of un-commenting the four cluster-mode lines per
component's `kustomization.yaml`, not a rewrite.

{{< cards >}}
  {{< card link="/docs/platform/observability/metrics/" title="Metrics" icon="chart-bar" subtitle="VictoriaMetrics single vs cluster mode, metrics-server, and the VMServiceScrape/VMScrapeConfig scrape mechanisms." >}}
  {{< card link="/docs/platform/observability/logs/" title="Logs" icon="document-text" subtitle="VictoriaLogs, Vector as the shipper, kubernetes-event-exporter, loggen, and the LogsQL syntax rules that aren't optional." >}}
  {{< card link="/docs/platform/observability/dashboards-and-alerts/" title="Dashboards & Alerts" icon="bell" subtitle="Grafana Operator's folder/dashboard/datasource model, VictoriaTraces, VMRule alerting, Alertmanager routing to RunLore and Slack, and the undeployed Grafana OnCall." >}}
  {{< card link="/docs/platform/observability/postgresql/" title="PostgreSQL" icon="database" subtitle="CloudNativePG's pg_stat_statements metrics, the Vector pipeline that parses auto_explain plans, and Barman Cloud plugin backups." >}}
{{< /cards >}}
