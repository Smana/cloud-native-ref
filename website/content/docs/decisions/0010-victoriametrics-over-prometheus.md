---
title: Use VictoriaMetrics rather than Prometheus
linkTitle: 0010 · VictoriaMetrics
weight: 100
description: Metrics, logs and traces run on the VictoriaMetrics family rather than Prometheus, Loki and Tempo, for one operator model and one Grafana across all three signals.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context

Observability on this platform spans three signals — metrics, logs and
traces — and each one needs both a storage/query backend and a way to feed
Grafana and alerting. The conventional CNCF answer is three separately
maintained projects: Prometheus for metrics, Loki for logs, Tempo for
traces, each with its own operator (or lack of one), its own configuration
model, and its own Grafana datasource plugin.

`observability/base/` instead runs three components from one project
family — `victoria-metrics-k8s-stack`, `victoria-logs`, `victoria-traces` —
sharing a single Helm repository, a single Kubernetes operator
(`operator.victoriametrics.com/v1beta1`), and one Grafana instance that all
three feed. `victoria-metrics-k8s-stack` is built as a direct structural
equivalent of `kube-prometheus-stack`: VictoriaMetrics itself, vmagent,
Alertmanager, a bundled Grafana subchart, and the same default
recording/alerting rule set, which is what makes "swap in
kube-prometheus-stack instead" a real, comparable alternative rather than a
hypothetical one.

---

## Decision Drivers

- **One operator, one CRD family, for both scrape configuration and
  alerting.** `VMServiceScrape` and `VMScrapeConfig` cover target
  discovery; `VMRule` covers alerting rules for metrics and logs alike.
- **Wire-protocol compatibility with the ecosystem this platform already
  writes against.** VictoriaMetrics speaks the Prometheus scrape and
  remote-write protocols and evaluates PromQL directly, so existing
  dashboards and PromQL alerting rules port unchanged.
- **Resource footprint at the retention the platform actually runs.**
  Every component here — `vmsingle`, `vlsingle`, `vtsingle` — is deployed
  single-binary. Explicit CPU/memory requests and limits are set where
  they have been sized — the VictoriaLogs and VictoriaTraces servers, the
  VictoriaLogs-side `vmalert`, and grafana-operator; `vmsingle`, vmagent,
  Alertmanager, Grafana and the exporters run on chart defaults, with
  right-sizing deferred until live usage data exists.
- **One Grafana, three signals, cross-linked out of the box.** Grafana's
  trace-to-log and trace-to-metric correlation (`tracesToLogs`,
  `tracesToMetrics`, and a `TraceID` derived field on the logs datasource)
  is configured once, against same-vendor datasources.
- **A scale-out path that doesn't require re-architecting.** Cluster-mode
  charts for VictoriaMetrics and VictoriaLogs already exist on disk, ready
  to be un-commented, rather than needing a second migration later.

---

## Considered Options

### Option 1: VictoriaMetrics family (VictoriaMetrics, VictoriaLogs, VictoriaTraces)

**Pros**:
- One operator and one CRD family — `VMServiceScrape`/`VMScrapeConfig` for
  scrape targets, `VMRule` for alerting — instead of a Prometheus-only CRD
  set for metrics and a separate, non-CRD configuration model for logs and
  traces. The same `VMRule` CRD carries both PromQL-typed groups (against
  VictoriaMetrics) and LogsQL-typed groups (`type: vlogs`, against
  VictoriaLogs); each signal runs its own `VMAlert` instance, but both are
  the same CRD kind read through the same `ruleSelector`-label mechanism,
  not two unrelated alerting systems.
- Single-binary-first components with a modest footprint at the retention
  this cluster actually runs — lower resource consumption at equivalent
  retention than a comparable Prometheus/Loki/Tempo deployment, though this
  repository has not run a side-by-side measurement to attach a number to
  that.
- Existing PromQL dashboards and alerting rules work unchanged, because
  VictoriaMetrics is wire- and query-compatible with Prometheus.
- Cluster-mode variants for VictoriaMetrics and VictoriaLogs already exist
  as commented-out `HelmRelease`s in the same directories, so scaling out
  is a `kustomization.yaml` edit, not a new project to onboard.

**Cons**:
- Smaller community than Prometheus: fewer third-party dashboards, fewer
  Stack Overflow answers, fewer runbooks written assuming it.
- LogsQL is its own query language, not PromQL and not Loki's LogQL —
  every query written from Loki-flavored muscle memory needs translating.
- VictoriaMetrics and VictoriaLogs each ship two `HelmRelease` files
  (single and cluster) that have to be kept aligned by hand.

### Option 2: kube-prometheus-stack + Loki + Tempo

The conventional CNCF stack: Prometheus Operator's `kube-prometheus-stack`
chart for metrics, Grafana Loki for logs, Grafana Tempo for traces —
three separately maintained upstream projects.

**Pros**:
- Largest community and third-party ecosystem of any metrics stack;
  `ServiceMonitor`/`PrometheusRule` are close to a de facto standard, so
  most upstream Helm charts ship native support without extra shims.
- Loki and Tempo are also CNCF projects with active governance, and Tempo's
  TraceQL is a purpose-built trace query language.
- `victoria-metrics-k8s-stack`'s default rule set is a fork of
  `kube-prometheus-stack`'s, so this is a real drop-in alternative, not a
  hypothetical one — the migration path back exists if needed.

**Cons**:
- Three separately operated projects instead of one operator family: a
  Prometheus Operator CRD set for metrics, and separate, non-CRD
  configuration surfaces for Loki and Tempo, each with its own upgrade
  cadence and its own Grafana datasource plugin.
- No shared CRD across metrics and logs alerting the way `VMRule` gives
  this platform (one kind, `type: vlogs` for the log-flavored groups) —
  Loki's ruler config and Prometheus' `PrometheusRule` are two unrelated
  formats to author and keep in sync.
- Prometheus' TSDB is heavier at comparable retention than a
  single-binary VictoriaMetrics deployment for the scrape volumes this
  platform runs, by VictoriaMetrics' own well-documented positioning — not
  something this repository has independently measured.

### Option 3: A managed offering (Amazon Managed Prometheus / Grafana Cloud)

Metrics (and optionally logs/traces) hosted by AWS or Grafana Labs instead
of run in-cluster.

**Pros**:
- No operator, no storage, no scaling decisions for the platform to own at
  all — capacity and upgrades are the vendor's problem.
- Amazon Managed Prometheus speaks the same remote-write protocol and
  PromQL surface this platform's dashboards already assume.

**Cons**:
- Recurring cost tied to ingested samples/log volume/traces rather than
  cluster capacity already being paid for, at a workload this platform
  runs for reference and demonstration purposes.
- A dependency on connectivity out of the cluster (over Tailscale/VPC
  routing this platform already restricts by design) for something as
  operationally central as alerting — an outage in the path to the vendor
  degrades observability of the outage itself.
- Doesn't remove the in-cluster scrape/log-shipping/alerting configuration
  surface (`VMServiceScrape`-equivalents still have to exist somewhere);
  it only relocates storage and query, while adding a vendor dependency
  this reference platform doesn't otherwise have.

---

## Decision Outcome

**Chosen option**: "Option 1 — VictoriaMetrics family"

**Rationale**: This platform already needs an operator-driven, CRD-based
configuration surface for every other component it runs — Crossplane,
Flux, Cilium — and VictoriaMetrics gives metrics and logs the same shape:
`VMServiceScrape`/`VMScrapeConfig` for what to scrape, `VMRule` for what to
alert on — the same CRD kind whether the rule group is PromQL or
LogsQL-typed. Option 2 is a legitimate, larger-community alternative — the
platform's own default alerting rules are literally forked from it — but it
buys that community at the cost of three independently operated projects
instead of one, with no shared CRD or alerting mechanism between them.
Option 3 removes operational burden but adds a recurring cost and an
external dependency that a reference platform demonstrating self-hosted
GitOps patterns should not default to.

---

## Consequences

### Positive

- One operator and one CRD family (`VMServiceScrape`, `VMScrapeConfig`,
  `VMRule`) cover scrape configuration and alerting for both metrics and
  logs, rather than a Prometheus-only CRD set plus separate configuration
  models for logs and traces.
- Existing PromQL dashboards and alerting rules carry over unchanged,
  because VictoriaMetrics implements the Prometheus scrape/remote-write
  protocols and PromQL directly.
- One Grafana instance reads all three signals, with trace-to-log and
  trace-to-metric correlation configured against same-vendor datasources.
- Scaling out is un-commenting the already-authored cluster-mode
  `HelmRelease`s for VictoriaMetrics and VictoriaLogs, not a second
  migration.

### Negative

- **Smaller community than Prometheus.** Fewer third-party dashboards ship
  ready-made, fewer runbooks and Stack Overflow answers assume this stack,
  so troubleshooting leans more on the project's own documentation and
  less on generic Prometheus knowledge.
  - *Mitigation*: PromQL compatibility means most Prometheus-oriented
    troubleshooting knowledge still applies to the metrics side; it is
    specifically LogsQL and the operator's own CRDs that need
    project-specific familiarity.
- **LogsQL is not PromQL and not Loki's LogQL.** Kubernetes label fields
  use dot notation (`kubernetes.container_name`, not
  `kubernetes_container_name`), and after `| unpack_json` every field
  gains a `log.` prefix (`log.level`, `log.trace_id`). Both rules are
  documented as easy to get wrong because a wrong query returns zero
  results silently rather than an error — there is no query-time signal
  that the field name was the problem. Every query written from Loki or
  general LogQL experience has to be translated, not just copy-pasted.
  - *Mitigation*: the syntax rules and worked examples are captured in
    [`.claude/rules/observability.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/observability.md)
    and on the [Logs]({{< relref "/docs/platform/observability/logs.md" >}})
    page, specifically because they are non-obvious enough to need writing
    down once rather than rediscovering per incident.
- **VictoriaMetrics and VictoriaLogs each ship two `HelmRelease` files —
  single and cluster — that have to be kept aligned by hand.** Both
  directories carry `helmrelease-vmsingle.yaml`/`helmrelease-vmcluster.yaml`
  and `helmrelease-vlsingle.yaml`/`helmrelease-vlcluster.yaml`, with only
  the single variant wired into `kustomization.yaml` today; a value
  changed on one side (resources, retention, alerting) and not mirrored on
  the other side goes unnoticed until the cluster variant is switched on.
  VictoriaTraces does not carry this split — it ships single-mode only.
  - *Mitigation*: partial. The Vector pipeline — the block that actually
    diverged — is now shared between both VictoriaLogs variants via the
    `vl-common-helm-values` ConfigMap (2026-08-30), so it can no longer
    drift; the remaining variant-specific values are still a diff to check
    by hand, not something CI enforces.

### Neutral

- Traces are not queried through a VictoriaMetrics-specific query
  language the way metrics and logs are. VictoriaTraces' Grafana
  datasource is configured with `type: jaeger`, querying through a
  Jaeger-compatible API rather than a bespoke VictoriaMetrics query
  surface. The "one operator family" consolidation therefore applies most
  fully to metrics and logs, which share `VMRule`-based alerting; traces
  join the same Grafana instance and the same vendor's Helm charts, but
  keep a query interface of their own.
- The active deployment runs single-node VictoriaMetrics at `1d` retention
  — explicitly commented in the chart values as "Minimal retention, for
  tests only" — so the resource-footprint advantage claimed above is not
  currently being exercised at production-equivalent retention on this
  cluster; it becomes a live comparison only once cluster mode (`10d`
  retention) is switched on.

---

## Implementation Notes

`victoria-metrics-k8s-stack`, `victoria-logs`, and `victoria-traces` each
install as a `HelmRelease` from the same `victoria-metrics` `HelmRepository`
source. Only the `*single` `HelmRelease`/`HTTPRoute`/dashboard resources
are active in each `kustomization.yaml`; the `*cluster` counterparts are
present on disk and commented out. Common values shared between single and
cluster mode for the metrics stack live in
`vm-common-helm-values-configmap.yaml`, applied via `valuesFrom` — this is
where the EKS-managed control-plane rule groups
(`kubernetes-system-apiserver`, `-controller-manager`, `-scheduler`) are
disabled, since EKS runs those as a managed service this cluster cannot
scrape and their default `absent()`-based alerts would otherwise fire
permanently.

`VMRule` spans both query languages by way of its `spec.groups[].type`
field: omitted (defaults to `prometheus`) evaluates against VictoriaMetrics,
`vlogs` evaluates against VictoriaLogs. The one deployed
example of the latter is `observability/base/loggen/demo-vmrule.yaml`,
selected by `victoria-logs`'s own `VMAlert` via a `vmlog: "true"` label
that the metrics-side `VMAlert` does not match.

---

## References

- [Metrics]({{< relref "/docs/platform/observability/metrics.md" >}}) — the
  VMServiceScrape/VMScrapeConfig scrape mechanisms, and single vs cluster
  mode for VictoriaMetrics
- [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) — VictoriaLogs,
  Vector as the shipper (decision recorded in
  [ADR-0030](0030-vector-as-log-shipper.md)), and the LogsQL syntax rules
- [Observability]({{< relref "/docs/platform/observability/_index.md" >}}) —
  "Why VictoriaMetrics and VictoriaLogs", and the shared-operator/shared-Grafana
  rationale this record formalizes
- [`.claude/rules/observability.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/observability.md)
  — LogsQL field-naming rules and Grafana dashboard conventions
- `observability/aws-0/victoria-metrics-k8s-stack/vmrules/karpenter.yaml`,
  `vmservicecrapes/karpenter.yaml` — `VMRule`/`VMServiceScrape` authored
  directly, outside a chart's own `valuesFrom` toggle
- `observability/base/loggen/demo-vmrule.yaml` — the one deployed
  `type: vlogs` `VMRule`, evaluated by VictoriaLogs' own `VMAlert`
- `observability/base/victoria-traces/grafana-datasource.yaml` — the
  Jaeger-compatible datasource type backing trace queries
- This record supersedes the two-line note the site previously carried under
  "The ones without records", which is what prompted the backfill
