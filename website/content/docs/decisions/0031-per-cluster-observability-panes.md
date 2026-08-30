---
title: Per-cluster observability panes; Slack and RunLore are the pager
linkTitle: 0031 · Per-cluster panes
weight: 310
description: Each cluster runs its own complete observability stack with no cross-cluster federation; the one shared pane is the Slack alerts channel, kept attributable by a cluster external label on every vmalert. Alerts terminate in Slack and RunLore — there is no human pager and, for now, no dead-man's switch.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-30
**Deciders**: Platform Team

---

## Context

The platform runs two clusters, and each runs the full observability stack
self-contained: VictoriaMetrics, VictoriaLogs, VictoriaTraces and Grafana.
There is no cross-cluster remote-write, no vmauth federation layer, and no
Grafana configured with the other cluster's datasources. The operator
experience is two panes — `grafana.priv.aws.ogenki.io` and
`grafana.priv.gcp.ogenki.io` — checked separately.

The single shared pane is the Slack `#alerts` channel. Both clusters'
Alertmanagers post into it, and alerts stay attributable because a `cluster`
external label is stamped on **vmalert** — both instances per cluster, the
metrics-side one and VictoriaLogs' own. It is stamped there, not only on
vmagent, after a documented incident: most upstream rules aggregate with
`sum(...) by (...)`, which drops vmagent-level labels, so alerts arrived in
the shared channel with an empty `cluster` and no way to tell which platform
was complaining.

This record makes the topology a decision rather than an accumulation, and
writes down the alerting stance that goes with it.

---

## Decision Drivers

- **Cost.** A third always-on pane, or doubled egress and storage, for a
  two-cluster reference platform.
- **Blast-radius isolation.** One cluster's observability outage must not
  blind the operator to the other cluster.
- **A concrete operational hazard on the federation path.** Cross-cluster
  write traffic would traverse the platform's cert-gated Tailscale L7
  endpoints, and machine-to-machine retry loops against those are a
  connection-stampede generator (see Option 3's cons).
- **Honesty about the pager.** The alerting design should state where alerts
  terminate, not imply an escalation chain that does not exist.

---

## Considered Options

### Option 1: Two self-contained panes + shared Slack channel

Each cluster keeps its full stack; the only cross-cluster surface is both
Alertmanagers posting to `#alerts`, with the `cluster` external label carrying
attribution.

**Pros**:
- Zero standing cross-cluster infrastructure and zero added egress/storage
  cost.
- Full isolation: an observability outage on one cluster cannot degrade the
  other's, or the operator's view of the other's.
- The shared surface (Slack) is owned by neither cluster, so it survives
  either one dying — which is exactly when it is needed.

**Cons**:
- No single query surface: comparing the two clusters means two Grafana tabs
  and mentally joining them.
- Alert attribution hangs on the `cluster` external label being stamped
  everywhere alerts originate — a per-vmalert obligation that has already
  been missed once.

### Option 2: Thin global read layer

Keep storage per-cluster, add a global *read* pane: vmauth fanning queries out
to both clusters, or one Grafana holding both clusters' datasources over
Tailscale.

**Pros**:
- One pane of glass without duplicating storage; queries federate at read
  time.
- The smallest step up from Option 1 if a real need appears.

**Cons**:
- A standing machine-to-machine dependency through the cert-gated Tailscale
  L7 endpoints — the exact path on which retrying clients have already pinned
  a tailnet-wide `SetDNS` 429 for hours against ACME rate limits.
- The read layer becomes a third thing to run, and its outage recreates the
  "one pane down" problem it was meant to solve.

### Option 3: Full remote-write federation to one store

Both clusters remote-write metrics (and ship logs) to a single global stack;
one Grafana, one alerting point.

**Pros**:
- Genuinely one pane: cross-cluster queries, dashboards and alerts with no
  mental join.

**Cons**:
- Doubled egress and storage plus a third always-on stack, for two clusters.
- The global store becomes a single point of blindness: its outage blinds
  *both* clusters at once.
- The write path is continuous machine-to-machine traffic through cert-gated
  Tailscale L7 endpoints — the connection-stampede/ACME-rate-limit hazard
  above, but permanent and load-bearing. If federation is ever adopted, the
  write path must be exposed at L4, not through the cert-gated L7 gateways.

---

## Decision Outcome

**Chosen option**: "Option 1 — two self-contained panes + shared Slack"

**Rationale**: For a two-cluster reference platform, both federation options
buy convenience with new standing infrastructure, new cost, and a shared
failure domain — and both route machine-to-machine traffic through the one
path this platform has already seen melt down under retry stampedes. Option 1
costs the operator a second browser tab and pays for it with total isolation:
the shared pane that remains (Slack) is external to both clusters and needs
neither of them alive.

**The alerting stance, stated plainly**: alerts terminate in Slack and
RunLore. There is **no human pager** — no escalation, no schedule, no
phone/push chain ([ADR-0029](0029-runlore-over-grafana-oncall.md)) — and
**no dead-man's switch**: the `Watchdog` heartbeat alert is deliberately
routed to the blackhole receiver, so a dead alerting pipeline is currently
indistinguishable from a quiet day.

---

## Consequences

### Positive

- No cross-cluster observability infrastructure to run, secure, or pay for.
- One cluster's observability outage cannot blind the other; the Slack pane
  survives either cluster's death.
- Alerts from both clusters land in one channel and stay attributable via the
  `cluster` external label on every vmalert instance.

### Negative

- **No single query surface.** Cross-cluster comparison is manual, across two
  Grafanas.
  - *Mitigation*: acceptable at two clusters; if it stops being acceptable,
    Option 2 at L4 is the designed next step.
- **No dead-man's switch.** With `Watchdog` blackholed and no external
  heartbeat, silence is ambiguous: healthy platform and dead alerting
  pipeline look identical. This is accepted **as temporary**, with a named
  follow-up: wire `Watchdog` to an external heartbeat monitor
  (healthchecks.io-style — a receiver that alerts when the heartbeat *stops*)
  in a future change.
- **The attribution label is an obligation, not a mechanism.** Every new
  alert-originating component (each vmalert) must stamp
  `externalLabels.cluster`; the VictoriaLogs vmalert shipped without it once
  and its alerts arrived anonymous.

### Neutral

- Grafana, dashboards and rules are duplicated per cluster by construction —
  the same GitOps base renders both, so duplication is in the cluster, not in
  the repo.

---

## Implementation Notes

The `cluster` external label is set in
`observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`
(metrics-side vmalert, and vmagent) and in
`observability/base/victoria-logs/vmalert-vlsingle.yaml` /
`vmalert-vlcluster.yaml` (VictoriaLogs-side), all as
`externalLabels: {cluster: "${cluster_name}"}` substituted per cluster by Flux.
The Alertmanager route — blackhole matcher for
`InfoInhibitor|Watchdog|KubeCPUOvercommit`, RunLore receiver with
`continue: true`, Slack receiver — lives in the same vm-common ConfigMap.

---

## References

- [ADR-0029](0029-runlore-over-grafana-oncall.md) — why RunLore + Slack is
  the whole pager, and what that gives up
- [ADR-0027](0027-primary-cloud-provider.md) — the per-cloud/singleton
  classification this topology follows: observability is per-cloud, the
  Slack channel is the cloud-agnostic shared surface
- `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`
  — the `cluster` external label (with the incident writeup in its comments)
  and the Alertmanager route
- `observability/base/victoria-logs/vmalert-vlsingle.yaml` — the
  VictoriaLogs-side vmalert stamping the same label, with the comment
  explaining why
