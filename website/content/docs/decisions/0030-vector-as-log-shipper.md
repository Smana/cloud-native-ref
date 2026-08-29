---
title: Vector as the log shipper
linkTitle: 0030 · Vector log shipper
weight: 300
description: Logs reach VictoriaLogs through Vector, deployed as the victoria-logs chart's own subchart, chosen over Fluent Bit, Promtail and the OpenTelemetry Collector for VRL's expressiveness and testability — the PostgreSQL auto_explain plan-history pipeline depends on both.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-30
**Deciders**: Platform Team
**Related Design**: N/A — backfill; records a choice carried over from the Loki era and re-affirmed at VictoriaLogs adoption

---

## Context

**This record is a backfill.** Vector has been the platform's shipper since
the Loki era (standalone vector-agent, October 2023); when VictoriaLogs
replaced Loki (May 2025) the choice was re-affirmed and Vector was re-deployed
as the victoria-logs chart's subchart.
[ADR-0010](0010-victoriametrics-over-prometheus.md) references "Vector as the
shipper" without ever deciding it. The reasoning below is written down after
the fact so it stops living only in the configuration.

Every node needs an agent that tails container logs and ships them to
VictoriaLogs. The platform runs Vector for this, deployed not as its own
release but as the `victoria-logs` Helm chart's Vector subchart — a DaemonSet
on both clusters, configured through the same `HelmRelease` as the log store
itself.

The configuration is not a stock catch-all. It carries a bespoke pipeline of
roughly 460 lines: a CloudNativePG `auto_explain` extraction stage — VRL
transforms that detect PostgreSQL plan output, parse the embedded JSON plan
and its metadata, and ship it structured — plus the catch-all stage with the
VictoriaLogs-specific headers. The VRL carries in-file unit tests runnable
with `vector test`. As of 2026-08-30 the whole pipeline is shared across both
`victoria-logs` chart variants (single and cluster) via the
`vl-common-helm-values` ConfigMap, after the cluster variant was found to have
never carried it — it shipped with a stock Vector and no customConfig at all.

---

## Decision Drivers

- **The auto_explain pipeline is a headline platform feature** (PostgreSQL
  query-plan history in Grafana), and it needs a transform language expressive
  enough to parse mixed text-plus-JSON log lines — with unit tests, because a
  wrong parse fails silently.
- **Operational footprint.** A shipper that installs as a subchart of the log
  store it feeds is one `HelmRelease`, one upgrade cadence, zero extra
  releases to operate.
- **Upstream blessing.** The VictoriaLogs documentation names Vector as a
  recommended ingestion agent and documents the exact sink configuration.

---

## Considered Options

### Option 1: Vector (as the victoria-logs chart's subchart)

**Pros**:
- VRL is a real transform language: the auto_explain extraction (detect,
  filter, parse plan JSON, annotate) is expressible directly, and `vector
  test` runs the in-file unit tests against it — the only option here with a
  first-class transform-testing story.
- First-party integration: the `victoria-logs` chart ships Vector as a
  subchart, so shipper and store configure, version and upgrade together in
  one `HelmRelease`.
- Named by the VictoriaLogs docs as a supported, documented ingestion path.

**Cons**:
- Vector is Datadog-owned — an acquisition-shaped risk for a vendor whose
  commercial interest is its own platform.
- The pipeline is repo-owned complexity (~460 lines of VRL and sink config)
  that must be ported if the shipper ever changes.

### Option 2: Fluent Bit

**Pros**:
- Lighter footprint — a small C binary, the conventional choice for
  resource-constrained DaemonSets.
- Large ecosystem and long production history.

**Cons**:
- No VRL: the auto_explain pipeline would be Lua scripts and filter chains,
  with no unit-test story for the parsing logic that most needs one.
- A separate release to operate alongside the `victoria-logs` chart.

### Option 3: Promtail

**Pros**:
- Simple, purpose-built log tailer with wide familiarity.

**Cons**:
- Loki-shaped: its label model and push protocol are designed for Loki, not
  VictoriaLogs.
- By the time of the 2025 re-affirmation, deprecated upstream — announced
  end-of-life in the Loki 3.x era, replaced by Grafana Alloy. Switching to it
  then would have meant starting on a dead branch.

### Option 4: OpenTelemetry Collector

**Pros**:
- The vendor-neutral standard; one collector could eventually carry all three
  signals.

**Cons**:
- Heavier configuration model (receivers/processors/exporters) with no VRL
  equivalent for the auto_explain parsing, and no in-config unit tests.
- The platform ships no OTel collector today; adopting one *for logs alone*
  would add the heaviest option to solve the narrowest problem.

### Option 5: vlagent (VictoriaMetrics' own shipper)

Did not exist at decision time, so it could not be chosen. Named here because
it is the watched successor candidate: a first-party VictoriaLogs shipper
removes both the vendor-risk and integration arguments for Vector, if and when
it matures to feature parity for this pipeline.

---

## Decision Outcome

**Chosen option**: "Option 1 — Vector as the victoria-logs subchart"

**Rationale**: The decision was effectively made by the auto_explain feature.
Only VRL expresses that extraction as testable code; Fluent Bit would bury it
in untested Lua, Promtail cannot express it at all, and the OTel Collector
buys standardization the platform doesn't yet need at the cost of the worst
config ergonomics for this job. The subchart deployment then made Vector the
cheapest option to operate as well — one `HelmRelease` covers shipper and
store.

---

## Consequences

### Positive

- The PostgreSQL plan-history feature exists: `auto_explain` output is parsed
  into structured, queryable plan documents at ship time, and the parsing
  logic has unit tests (`vector test`) that run without a cluster.
- One `HelmRelease` operates both the shipper and the store, on one upgrade
  cadence.

### Negative

- **Vector is Datadog-owned.** The project could be steered or slowed in
  favor of Datadog's own platform.
  - *Mitigation*: watch vlagent (Option 5); a mature first-party shipper is
    the designated exit.
- **The pipeline is repo-owned complexity** — roughly 460 lines of VRL,
  transforms and sink configuration that must move, and be re-tested, if the
  shipper ever changes.
  - *Mitigation*: the in-file unit tests are the portability insurance; they
    define the expected parses independently of Vector's runtime.

### Neutral

- Because the shipper rides the `victoria-logs` chart, its version is pinned
  by that chart's, not chosen independently.
- The shared `vl-common-helm-values` ConfigMap means the single and cluster
  chart variants can no longer diverge on the pipeline — the failure that
  motivated sharing it — but the remaining variant-specific values still
  align by hand.

---

## Implementation Notes

The pipeline lives in
`observability/base/victoria-logs/vl-common-helm-values-configmap.yaml`,
consumed via `valuesFrom` by both `helmrelease-vlsingle.yaml` and
`helmrelease-vlcluster.yaml`. Stages: a `filter_pg_auto_explain` transform
detects auto_explain output, `parse_pg_auto_explain` extracts the plan JSON
and metadata (VRL, with in-file unit tests), and dedicated sinks ship parsed
plans and the catch-all stream to VictoriaLogs with the appropriate
`AccountID`/stream headers. Only the two PG sinks are shared — the cluster
chart ships its own catch-all sink, and sharing ours would have doubled every
general log line in cluster mode — caught while the cluster variant was still
on standby.

---

## References

- [ADR-0010](0010-victoriametrics-over-prometheus.md) — the VictoriaLogs
  adoption this shipper choice rode in on
- [Logs]({{< relref "/docs/platform/observability/logs.md" >}}) — Vector's
  place in the log flow
- `observability/base/victoria-logs/vl-common-helm-values-configmap.yaml` —
  the shared pipeline: transforms, unit tests, sinks
- [VictoriaLogs data-ingestion docs](https://docs.victoriametrics.com/victorialogs/data-ingestion/vector/)
  — the upstream-documented Vector integration
