---
title: Metrics
weight: 10
description: VictoriaMetrics single vs cluster mode, metrics-server, and the VMServiceScrape/VMScrapeConfig mechanisms that feed both.
lastVerified: 2026-08-30
---

## VictoriaMetrics k8s stack

`observability/base/victoria-metrics-k8s-stack/` deploys the
`victoria-metrics-k8s-stack` chart (0.91.2) — the kube-prometheus-stack
equivalent: VictoriaMetrics itself, vmagent, Alertmanager, a bundled Grafana
subchart, and the default recording/alerting rule set. Only `vmsingle` is
active; `vmcluster` sits in the same directory, fully valued, commented out
of `kustomization.yaml`.

| | vmsingle (active) | vmcluster (standby) |
|---|---|---|
| Retention | `14d` — deliberate as of 2026-08-30; sized to fit the 10Gi PVC at this fleet's ingest rate | `10d` |
| Replication | `replicaCount: 1` | `replicationFactor: 2`, separate `vmstorage`/`vmselect`/`vminsert` with zone-aware anti-affinity |
| Storage | 10Gi RWO | 10Gi (`vmstorage`) + 2Gi (`vmselect` only — `vminsert` is stateless), platform default class (`gp3` on aws-0, `standard-rwo` on gcp-0) |
| Alertmanager | `replicaCount` unset (chart default) | `replicaCount: 2` |

`aws-0`'s overlay (`observability/aws-0/victoria-metrics-k8s-stack/`)
carries the AWS-only pieces on top of the base — `vmrules/karpenter.yaml`,
`vmservicecrapes/karpenter.yaml`, and
`vmscrapeconfigs/ec2.yaml` — moved out of the base because the `karpenter`
namespace does not exist on `gcp-0`, where they failed the whole
Kustomization. (RunLore's alerts used to sit in the same overlay; they moved
to the base on 2026-08-30, because the agent runs on both clusters.) Common values shared
by both modes (`vm-common-helm-values-configmap.yaml`, applied via
`valuesFrom`) disable the control-plane rule groups (`kubernetes-system-apiserver`,
`-controller-manager`, `-scheduler`) — EKS runs these as a managed service
this cluster can't scrape, so the chart's default `absent()`-based `*Down`
alerts would otherwise fire permanently — and disable `kubeProxy` scraping
for the same reason Cilium replaces it.

{{< callout type="info" >}}
Retention was `1d` — chart-commented "Minimal retention, for tests only" —
for the repository's entire life until 2026-08-30, when it became a
deliberate `14d`. VictoriaMetrics OSS has no disk-based retention cap; the
safety valve is `-storage.minFreeDiskSpaceBytes`, which rejects **new**
writes below the threshold rather than deleting old data — lossless only
while vmagent's own disk buffer absorbs the outage, not an unconditional
guarantee.
{{< /callout >}}

## metrics-server

`observability/base/metrics-server/` runs the standard `metrics-server`
chart (3.14.0) — but into `kube-system`, not `observability`, since it backs
`kubectl top` and HPA `Resource` metrics cluster-wide. On `aws-0` only: GKE
ships its own managed metrics-server, and running ours beside it did nothing
but fight the addon manager (the header of
`observability/gcp-0/kustomization.yaml` has the full story). Non-default
configuration worth knowing:

- `replicas: 2` with a `PodDisruptionBudget` (`maxUnavailable: 1`) and
  hostname anti-affinity — HA by default, not a single point of failure for
  every HPA in the cluster.
- `args: [--kubelet-insecure-tls]` — required on EKS; the kubelet serving
  certificate isn't signed by a CA metrics-server trusts otherwise.
- `serviceMonitor.enabled: true` with `additionalLabels.prometheus: victoria-metrics-k8s-stack`
  so vmagent picks it up.

## Scrape mechanisms

Three CRDs from the VictoriaMetrics Operator cover how targets get
discovered, each used somewhere in this repo:

**`VMServiceScrape`** — the ServiceMonitor equivalent, scrapes a `Service`'s
endpoints. Most charts in this repo render their own via a
`vmServiceScrape.enabled: true` value (`runlore`, `victoria-traces`,
`victoria-logs`, `victoria-metrics-k8s-stack` itself); a few are authored
directly, e.g. `observability/aws-0/victoria-metrics-k8s-stack/vmservicecrapes/karpenter.yaml`
scrapes the `karpenter` namespace's `http-metrics` port (Karpenter isn't part
of this stack, but its metrics land in the same VictoriaMetrics — the
directory name carries an upstream typo, `vmservicecrapes`, not
`vmservicescrapes`). KEDA is scraped the same way since 2026-08-30:
`infrastructure/base/keda/vmservicescrape.yaml` covers both the operator and
the metrics-apiserver on both clouds — the metrics had been exposed since
KEDA was installed, but nothing ever scraped them.

**`VMScrapeConfig`** — for targets that aren't a Kubernetes `Service` at all.
Two examples in `vmscrapeconfigs/`:

```yaml
# observability/base/victoria-metrics-k8s-stack/vmscrapeconfigs/openbao.yaml
staticConfigs:
  - targets:
      - "bao.${private_domain_name}:8200"
    labels:
      job: openbao
scheme: HTTPS
tlsConfig:
  ca:
    secret:
      name: openbao-ca
      key: ca.crt
  serverName: "bao.${private_domain_name}"
path: /v1/sys/metrics
```

OpenBao is scraped by DNS name over HTTPS with a real CA, not EC2 service
discovery — the instance security group only admits the internal NLB on
8200, and the server certificate carries a single DNS SAN, so scraping
individual instance IPs could never verify TLS. `ec2.yaml`
(in `aws-0`'s overlay, `observability/aws-0/victoria-metrics-k8s-stack/vmscrapeconfigs/`
— EC2 service discovery is AWS-only) is the EC2-SD counterpart, used for
node-exporter (tag
`observability:node-exporter=true`, port 9100) where per-instance scraping is
fine.

**`VMPodMonitor`** — scrapes Pods directly rather than through a Service.
Not currently used by any component in this repo; if you add one, it renders
the same way `VMServiceScrape` does.

## Example queries

Written against metrics this cluster actually exposes, not generic
placeholders:

```promql
# RunLore agent missing entirely (real alert: RunloreAgentDown)
absent(runlore_build_info)

# CloudNativePG: call volume by database, from the query-performance dashboard
sum by (database) (rate(cnpg_pg_stat_statements_calls[5m]))

# RunLore model-request p95 latency (real alert: RunloreModelLatencyHigh)
histogram_quantile(0.95, sum(rate(runlore_model_request_duration_seconds_bucket[15m])) by (le))
```

The first two are drawn directly from
`observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml` and
`infrastructure/base/cloudnative-pg/grafana-dashboard-query-performance.yaml`.
Standard cAdvisor/kube-state-metrics queries (`container_cpu_usage_seconds_total`,
`kube_pod_status_phase`, and similar) also work unchanged — they come from
the bundled `kube-state-metrics`/`node-exporter` subcharts, not from
anything specific to this repo.

{{< callout type="warning" >}}
No `CiliumNetworkPolicy` exists in `victoria-metrics-k8s-stack/` or
`metrics-server/` for either component. Of the eight observability component
directories, only `runlore` ships one — see
[Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}})
for the CiliumNetworkPolicy it does define, and for the CiliumClusterwideNetworkPolicy
that isn't a default-deny (it only allows the Gateway API L7 proxy).
{{< /callout >}}
