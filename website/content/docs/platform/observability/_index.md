---
title: Observability
weight: 40
description: VictoriaMetrics, VictoriaLogs, and VictoriaTraces under one Grafana, the SRE agent that reacts to their alerts, and why one of nine component directories never actually deploys.
lastVerified: 2026-08-27
---

`observability/base/` holds nine component directories. **Eight are wired
into Flux; one is not.** `grafana-oncall` is a fully-built HelmRelease pair
(engine + RabbitMQ, external Postgres and Valkey already provisioned) that no
`Kustomization` anywhere in `clusters/` or `flux/` ever references — it does
not run on the cluster today. Every other component below does — on
`aws-0`; `gcp-0` runs seven of the eight, because `runlore` stays AWS-only
for now (its HelmRelease hardcodes `cloud.provider: aws` and its identity is
an EKS Pod Identity — the header of `observability/gcp-0/kustomization.yaml`
records what a GCP wiring still needs). See
[Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md#grafana-oncall-built-but-not-deployed" >}})
for what that means in practice.

![Where a metric, a log and a span go: vmagent scrapes Pods, Services and OpenBao into single-node VictoriaMetrics, Vector ships container stdout and Kubernetes Events into VictoriaLogs, and applications push OTLP spans straight to VictoriaTraces; one Grafana reads all three, while a VMAlert instance per signal evaluates PromQL and LogsQL rules authored through the same VMRule mechanism and Alertmanager fans every surviving alert to both RunLore and Slack](/images/diagrams/observability-flow.svg)

| Component | Deployed via | Documented in |
|---|---|---|
| `victoria-metrics-k8s-stack` | `observability-victoria-metrics-k8s-stack` Kustomization | [Metrics]({{< relref "/docs/platform/observability/metrics.md" >}}) |
| `metrics-server` | `observability` Kustomization | [Metrics]({{< relref "/docs/platform/observability/metrics.md" >}}) |
| `victoria-logs` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `kubernetes-event-exporter` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `loggen` | `observability` Kustomization | [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) |
| `victoria-traces` | `observability-victoria-traces` Kustomization | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}) |
| `grafana-operator` | `observability-grafana-operator` Kustomization | [Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}) |
| `runlore` | `observability` Kustomization | [SRE agent]({{< relref "/docs/platform/observability/sre-agent.md" >}}) |
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
`VMScrapeConfig`, `VMAlert`) and one Grafana, so a rule is a `VMRule` whether
it is PromQL against VictoriaMetrics or LogsQL (`type: vlogs`) against
VictoriaLogs — one authoring surface for both signals.

Each signal still runs its **own** `VMAlert` instance, because each needs its
own datasource: the one bundled with `victoria-metrics-k8s-stack` evaluates
the PromQL rules, and `vmalert-vlsingle.yaml` defines a second, scoped by
`ruleSelector.matchLabels.vmlog: "true"`, that evaluates the LogsQL ones. A
rule missing that label is invisible to it. See
[`loggen`'s alert]({{< relref "/docs/platform/observability/logs.md#alerting-on-logs" >}})
for a concrete `type: vlogs` example. No ADR in this repository records the
comparison against Prometheus/Loki directly; treat this section as the
current rationale, not a linked decision record.

## No cloud-provider monitoring, on either cloud

Neither CloudWatch on AWS nor Cloud Logging and Monitoring on GCP is used. Every
metric, log and trace on both clusters goes to the VictoriaMetrics stack above,
and that is the only place to look.

This is a deliberate consequence of running the same platform on two clouds: an
observability stack that lives *inside* the cluster is identical on both, so a
dashboard, a `VMRule` or a LogsQL query written once works on `aws-0` and
`gcp-0` without translation. A cloud-native stack would mean two of everything
and two query languages, for signals that are already being collected.

It has a cost consequence worth stating plainly, because it was not free by
default:

- **EKS control-plane logging is off** (`enabled_log_types = []` in
  `opentofu/aws/eks/init/main.tf`). It shipped all five types to CloudWatch and
  billed **$144/month** — 20% of the entire AWS bill and its largest single
  line, essentially all of it the audit log. Nothing read any of it.
- GKE's equivalent, Cloud Logging ingestion for the cluster, is likewise not
  something the platform consumes.

**What that means if you need them.** Control-plane audit logs are genuinely
useful during a security investigation, and they are the one thing the in-cluster
stack cannot reconstruct — the API server writes them before anything the cluster
runs can see them. Turn them on deliberately when you need them, and expect the
bill: `enabled_log_types = ["audit"]` and re-apply `eks/init`.

See [What it costs]({{< relref "/docs/get-started/costs.md" >}}) for the full
breakdown.

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
  {{< card link="/docs/platform/observability/sre-agent/" title="SRE agent" icon="lightning-bolt" subtitle="RunLore — receives Alertmanager webhooks, investigates read-only against the live cluster, and writes what it learns back to a knowledge-base repository." >}}
  {{< card link="/docs/platform/observability/postgresql/" title="PostgreSQL" icon="database" subtitle="CloudNativePG's pg_stat_statements metrics, the Vector pipeline that parses auto_explain plans, and Barman Cloud plugin backups." >}}
{{< /cards >}}
