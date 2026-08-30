---
title: Dashboards & Alerts
weight: 30
description: Grafana Operator's folder/dashboard/datasource model, the pinned datasource plugins, VictoriaTraces, VMRule alerting, and Alertmanager routing to RunLore and Slack.
lastVerified: 2026-08-30
---

## Grafana Operator

`observability/base/grafana-operator/` installs `grafana-operator` (5.25.0),
but it does not deploy its own Grafana. Its `Grafana` custom resource
(`grafana-victoriametrics.yaml`) is configured as **external**, pointing at
the Grafana subchart already bundled inside `victoria-metrics-k8s-stack`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana-victoriametrics
  labels:
    dashboards: "grafana"
spec:
  external:
    url: http://victoria-metrics-k8s-stack-grafana
    adminPassword:
      name: victoria-metrics-k8s-stack-grafana-envvars
      key: GF_SECURITY_ADMIN_PASSWORD
```

grafana-operator's actual job here is reconciling `GrafanaFolder`,
`GrafanaDashboard`, and `GrafanaDatasource` CRs against that one external
instance. Every such CR in this repo carries the same two fields:
`instanceSelector.matchLabels.dashboards: "grafana"` (matches the `Grafana`
CR's own label above) and `allowCrossNamespaceImport: true` (folders and
dashboards are defined across `apps`, `infrastructure`, and `observability`
namespaces, all targeting the one Grafana in `observability`).

### Folder registry

A repo-wide grep for `kind: GrafanaFolder` finds nine CRs. Eight reconcile onto
the cluster by default, each defined in the namespace that owns its
dashboards; the ninth (`llm`, `apps/base/ai/llm/grafana-folder.yaml`) only
applies once the opt-in LLM platform's suspended umbrella Kustomization is
resumed (see CLAUDE.md's *Self-Hosted LLM Platform* section) and is out of
scope for this always-on page:

| Folder | Defined in | Holds |
|---|---|---|
| `apps` | `apps` | Demo "all-in-one" RED + trace/log correlation dashboard |
| `cilium` | `kube-system` | Cilium agent/operator and Hubble dashboards |
| `databases` | `infrastructure` | CloudNativePG query-performance and query-plan-correlation |
| `flux` | `flux-system` | Flux cluster and control-plane dashboards |
| `kubernetes` | `infrastructure` | Kubernetes views, node-exporter, Karpenter |
| `logs` | `observability` | VictoriaLogs explorer, single/cluster overview |
| `runlore` | `observability` | RunLore's own dashboard |
| `traces` | `observability` | VictoriaTraces overview |

### Dashboard inventory

| Dashboard | Folder | Source |
|---|---|---|
| `kubernetes-views-{global,namespaces,nodes,pods}` | `observability` | Imported — vendored by the `victoria-metrics-k8s-stack` chart |
| `kubernetes-node-exporter-full` | `kubernetes` | Authored in-repo |
| `kubernetes-karpenter` | `kubernetes` | Imported, [grafana.com dashboard 20398](https://grafana.com/grafana/dashboards/20398/) |
| `app-all-in-one` | `apps` | Authored in-repo |
| `runlore` | `runlore` | Authored in-repo |
| `observability-victoria-logs-explorer` | `logs` | Authored in-repo |
| `observability-victoria-logs-single` | `logs` | Imported, [dashboard 22084](https://grafana.com/grafana/dashboards/22084/) |
| `observability-victoria-traces-single` | `traces` | Imported, [dashboard 24136](https://grafana.com/grafana/dashboards/24136/) |
| `databases-cnpg-query-performance` / `-query-plan-correlation` | `databases` | Authored in-repo — see [PostgreSQL]({{< relref "/docs/platform/observability/postgresql.md" >}}) |
| `cilium-cilium`, `cilium-operator`, `cilium-hubble{,-dns-namespace,-l7-http-metrics,-network-overview-namespace}` (6 dashboards) | `cilium` | Imported, from the [cilium/cilium](https://github.com/cilium/cilium) upstream dashboard JSON |
| `flux-cluster`, `flux-control-plane` | `flux` | Imported, from [fluxcd/flux2-monitoring-example](https://github.com/fluxcd/flux2-monitoring-example) — pinned to commit `7ab65dc8` since 2026-08-30; tracking `refs/heads/main` made them mutate whenever upstream moved |

`victoria-logs` and `victoria-traces` also self-ship a dashboard via their
own chart's `dashboards.enabled: true, grafanaOperator.enabled: true` values,
targeting the same `logs`/`traces` folders as the manually-authored ones
above — two sourcing paths land in the same folder, which is redundant but
not a conflict (different dashboard names).

The victoria-metrics-k8s-stack chart's own `defaultDashboards` ships into an
`"observability"` folder (not one of the `GrafanaFolder` CRs above — it's
created implicitly by the chart's sidecar mechanism, not grafana-operator).
Its Kubernetes-views duplicates of the `kubernetes` folder's dashboards are
explicitly disabled in `vm-common-helm-values-configmap.yaml` to avoid
showing the same dashboard twice.

### Grafana itself: version and datasource plugins

The Grafana all of this lands in is the `victoria-metrics-k8s-stack`
subchart, its image pinned to `13.1.4` in
`vm-common-helm-values-configmap.yaml` — the stack constrains the subchart
to `grafana: 12.7.*`, so security releases need that explicit tag until the
stack bumps its dependency. The two VictoriaMetrics datasource plugins are
**pinned catalog installs** in the chart's `plugins:` list —
`victoriametrics-metrics-datasource@0.25.2` and
`victoriametrics-logs-datasource@0.31.0` — which the chart maps straight to
`GF_PLUGINS_PREINSTALL_SYNC`. Two details of that list are load-bearing: the
pin separator is `@`, not a space (a space is silently split into two bare
plugin ids, so the real plugin installs *unpinned*), and each pin carries a
Renovate annotation, so upgrades arrive as pull requests. This mechanism
replaced two curl `initContainers` on 2026-08-29: one frozen at `v0.14.0`
for 16 months, the other fetching GitHub "latest" on every pod start.

## VictoriaTraces

`observability/base/victoria-traces/` runs `victoria-traces-single` (0.1.11),
3-day retention, wired into Grafana as a Jaeger-protocol datasource. The `3d`
suffix in `retentionPeriod: 3d` matters: a unit-less `retentionPeriod: 3`
means 3 **months** in the VictoriaMetrics chart family, and that is what this
release silently kept — ×30 the intent — until the suffix was added on
2026-08-30. The datasource:

```yaml
# observability/base/victoria-traces/grafana-datasource.yaml
datasource:
  type: jaeger
  url: http://victoria-traces-vt-single-server.observability:10428/select/jaeger
  jsonData:
    tracesToLogs:
      datasourceName: VictoriaLogs
      tags: ['trace_id', 'traceId', 'traceID']
    tracesToMetrics:
      datasourceName: VictoriaMetrics
    nodeGraph:
      enabled: true
```

`tracesToLogs`/`tracesToMetrics` are what let a Grafana user pivot from a
trace span straight to the matching log lines (via `log.trace_id`, per the
[LogsQL rules]({{< relref "/docs/platform/observability/logs.md#logsql-syntax-rules" >}}))
or request-rate/latency panels, without re-typing a query by hand. The
manifest doesn't configure an explicit receiver protocol (no OTLP toggles) —
VictoriaTraces' chart defaults apply unmodified, so which ingest protocols
are actually enabled isn't determinable from this repo alone.

## Alerting

Two `VMRule` flavors coexist under the same `operator.victoriametrics.com/v1beta1`
API: implicit PromQL rules (the default) and explicit `type: vlogs` rules
evaluated as LogsQL — see [loggen's alert]({{< relref "/docs/platform/observability/logs.md#alerting-on-logs" >}})
for the LogsQL form. PromQL rules live mostly in
`victoria-metrics-k8s-stack/vmrules/` — in the base for both clusters unless
noted:

- `karpenter.yaml` — 3 alerts (node-registration failures, nodepool near
  capacity, cloud-provider errors) for a component this stack doesn't own
  but scrapes. Lives in the `aws-0` overlay
  (`observability/aws-0/victoria-metrics-k8s-stack/vmrules/`), because the
  `karpenter` namespace does not exist on `gcp-0`.
- `openbao.yaml` — 7 alerts (down, sealed, no active node, lost/at-risk Raft
  voter, snapshot job failed/stale), extensively commented with the incident
  history that motivated each one (an expired cert going unnoticed for 9
  months; a stale Raft voter silently halving failure tolerance).
- `runlore.yaml` — 12 alerts covering the agent's own health (down, no
  leader, split-brain), pipeline behavior (dropped/stalled/erroring
  investigations), and cost (token spend, model latency). Each carries a
  `runbook_url` pointing at RunLore's own docs. Moved from the `aws-0`
  overlay to the base on 2026-08-30, so the alerts follow the agent to both
  clusters. What the agent itself does with an alert is on its own page —
  [SRE agent]({{< relref "/docs/platform/observability/sre-agent.md" >}}).

```yaml
# observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml — trimmed
- alert: RunloreAgentDown
  expr: absent(runlore_build_info)
  for: 5m
  labels:
    severity: critical
  annotations:
    runbook_url: "https://github.com/Smana/runlore/blob/main/docs/observability.md#runloreagentdown"
```

### Alertmanager routing

Alertmanager's routing tree (`vm-common-helm-values-configmap.yaml`, applied
to the `victoria-metrics-k8s-stack` `alertmanager.spec.config`) fans every
non-blackholed alert to **both** RunLore and Slack:

```yaml
route:
  receiver: "slack-monitoring"
  routes:
    - matchers:
        - alertname =~ "InfoInhibitor|Watchdog|KubeCPUOvercommit"
      receiver: "blackhole"
    - receiver: "runlore"
      continue: true   # falls through to the next route instead of stopping
    - receiver: "slack-monitoring"
receivers:
  - name: "runlore"
    webhook_configs:
      - url: "http://runlore.runlore.svc:8080/webhook/alertmanager"
        http_config:
          authorization:
            credentials_file: /etc/vm/secrets/runlore-webhook-token/token
```

RunLore's webhook requires a bearer token (its v0.2.0+ fail-closed
behavior — alert labels/annotations flow into an LLM prompt, so an
unauthenticated trigger path was judged unacceptable) mirrored between its
own `runlore-webhook` `ExternalSecret` and this stack's
`runlore-webhook-token` `ExternalSecret`. The Slack receiver's `actions:`
list defines five button blocks: Runbook, Query (the alert's
`GeneratorURL`), Dashboard, and Silence — each sourced from the firing
alert's own annotations — plus a fifth built from the Monzo template's
`link_button_text`/`link_url` helpers. Whether that fifth button actually
renders on every message or only conditionally (e.g. when `link_url` is set)
can't be determined from this repo — the Monzo template it calls into isn't
vendored here, only referenced by name.

## Grafana OnCall (removed)

The former grafana-oncall directory under `observability/base/` — a complete
engine + RabbitMQ + Postgres + Valkey install that no Flux `Kustomization`
ever referenced — was
removed on 2026-08-29, along with the `grafana-oncall-app` plugin and the
provisioning ConfigMap that pointed it at an `oncall-engine` Service that
never existed. Upstream OnCall OSS is archived (read-only on GitHub since
2026-06-05, zero future patches), and the RunLore + Slack routing above
already carries the whole incident flow.
[ADR-0029]({{< relref "/docs/decisions/0029-runlore-over-grafana-oncall.md" >}})
records the decision and the full inventory of what was deleted.

## CiliumNetworkPolicy coverage

Of the eight component directories under `observability/base/`, only
**`runlore`** defines a `CiliumNetworkPolicy`:

```yaml
# observability/base/runlore/ciliumnetworkpolicy-ingress.yaml
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: runlore
  ingress:
    - fromEntities: [ingress]
      toPorts:
        - ports: [{port: "8080", protocol: TCP}]
```

It exists because runlore's HTTPRoute parents to `platform-public`
(described in [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}})),
and this cluster's shared `cilium-envoy` DaemonSet runs `hostNetwork: true` —
Gateway-originated traffic lands as Cilium's reserved `ingress` entity, which
a namespaced Kubernetes `NetworkPolicy` can never match. `grafana-operator`,
`kubernetes-event-exporter`, `loggen`, `metrics-server`,
`victoria-logs`, `victoria-metrics-k8s-stack`, and `victoria-traces` have no
`CiliumNetworkPolicy` in these directories, and no cluster-wide default-deny
`CiliumClusterwideNetworkPolicy` covers the `observability` namespace either
— the one such policy in this repo
(`infrastructure/base/gapi/allow-gateway-l7-proxy.yaml`) only allows the
Gateway API L7 proxy, it does not deny anything by default.
