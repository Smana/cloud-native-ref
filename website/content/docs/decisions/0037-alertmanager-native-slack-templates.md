---
title: Slack notifications are rendered by Alertmanager's own templates, not by a Block Kit bridge
linkTitle: 0037 · Alertmanager-native Slack templates
weight: 370
description: Alertmanager has no Block Kit support and has not had it since the request was filed in 2020, so richer Slack messages mean either a bridge in the notification path or better use of the legacy attachment format. The bridge is rejected because it duplicates RunLore's existing Slack integration for layout alone and fails silently when it fails. The information content of the message, not its chrome, was the actual problem.
lastVerified: 2026-09-12
---

**Status**: Accepted
**Date**: 2026-09-12
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0031](0031-per-cluster-observability-panes.md) — the per-cluster
observability split these messages have to be legible across;
[ADR-0029](0029-runlore-over-grafana-oncall.md) — the agent that already
holds a Slack app pointed at the same channel

---

## Context

Every alert on both clusters lands in one Slack channel, `#alerts`, rendered by
the **Monzo templates** that the `victoria-metrics-k8s-stack` chart vendors and
enables by default. They were written in 2018 for a single cluster. The platform
now runs two, on two clouds.

What that produced, verbatim, on 2026-09-12:

```
[FIRING:1] :warning: TargetDown
 • 100% of the core-dns/victoria-metrics-k8s-stack-core-dns targets in
   kube-system namespace are down.
```

Which cluster? The route already groups on `cluster`; the template never printed
it. The same message carried no environment, no cloud, no region, no namespace,
no duration, and — for rules whose `description` is a runbook — twelve lines of
shell pasted into the channel.

Slack marks the attachment format these templates use as legacy and steers new
integrations to Block Kit. So the question is not only *what should the message
say* but *what may render it*.

---

## Decision Drivers

- The message must name the cluster, environment, cloud and region, because two
  clusters on two clouds share one channel.
- Nothing may sit in the notification path that can fail silently. An alert that
  does not arrive is indistinguishable from no alert.
- The platform already runs one service holding a Slack app and posting to
  `#alerts` — RunLore. A second one needs to earn its keep.
- Whatever renders the message must be verifiable in CI without a cluster.

---

## Considered Options

### Option 1: Alertmanager's own templates, legacy attachments

Replace the vendored Monzo templates with repo-owned ones shipped through the
chart's `alertmanager.templateFiles`, and use the attachment format properly —
`fallback`, `fields`, `title_link`, per-severity `color`, and conditional button
URLs.

**Pros**:
- No new component in the notification path.
- Renderable offline: `amtool template render` executes the templates against
  fixture payloads with no cluster and no running Alertmanager, which makes a
  CI gate possible.
- The chart builds the ConfigMap and wires `VMAlertmanager.spec.templates`
  itself.

**Cons**:
- Bounded by what legacy attachments express: no accordions, no interactive
  elements beyond link buttons, at most five actions.
- Slack calls the format legacy, so this is a bet that it outlives its
  deprecation notice — one shared with every Alertmanager user.

### Option 2: Block Kit through a bridge

Route Alertmanager's webhook to a service that renders Block Kit and posts to
Slack — Robusta, or a small purpose-built relay.

**Pros**:
- The current Slack format, with layout the attachment API cannot express.
- Robusta additionally enriches alerts with pod logs and graphs.

**Cons**:
- A component in the notification path whose failure mode is silence.
- Duplicates RunLore's Slack integration — a second app, a second token, a
  second thing to operate — to buy layout.
- Alertmanager still has no Block Kit support
  ([prometheus/alertmanager#2217](https://github.com/prometheus/alertmanager/issues/2217),
  open since March 2020), so the bridge is permanent, not a stopgap.

### Option 3: Move alert routing to Grafana Alerting

Let Grafana own notification, which has its own Slack integration.

**Pros**:
- Actively developed notification layer.

**Cons**:
- Moves routing out of the VictoriaMetrics stack that owns the rules, splitting
  ownership of one concern across two systems.
- Out of proportion to a formatting problem.

---

## Decision Outcome

**Chosen option**: Option 1 — Alertmanager's own templates.

**Rationale**: The defects were informational, not decorative. A message that
names its cluster, shows its labels as fields, states how long the alert has
been firing and truncates a runbook instead of pasting it fixes every symptom
above, and the attachment format expresses all of it. Neither of the other
options addresses anything Option 1 leaves unaddressed; both add an operational
surface to buy layout.

The deciding property is verifiability. `amtool template render` makes the
message testable in CI against fixture payloads, so a template that would fail
to execute — and Alertmanager **drops** a notification whose template fails —
is caught before it reaches a cluster. A bridge would move rendering into a
service whose own failures are invisible from here.

---

## Consequences

### Positive

- No new service, token, or network hop in the path an alert takes to a human.
- The message is covered by a gate: every templated string is rendered against
  five fixture payloads and golden-compared, so a change to the wording shows up
  as a readable diff in review.
- Identity labels (`cluster`, `env`, `cloud`, `region`) are stamped by vmalert
  after rule evaluation, so no aggregation can drop them — the failure that
  produced `on cluster .` in a message.

### Negative

- Layout is capped by the attachment format. If a future message genuinely needs
  Block Kit, this is the record to revisit.
- The format is deprecated by Slack. Mitigation: nothing here depends on
  behaviour beyond `fallback`, `fields`, `color`, `title_link` and link buttons,
  which is the subset most likely to survive.

### Neutral

- Message wording now lives in a Go template inside a values ConfigMap rather
  than in a chart default. Editing it means regenerating golden files and
  reading the diff, which is slower and more deliberate than before.

---

## Implementation Notes

The templates ship via `alertmanager.templateFiles` in
`observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`,
with `monzoTemplate.enabled: false` removing the vendored set. Disabling it also
removes `__alert_silence_link`, which is redefined alongside ours.

Two traps bind anyone editing that block:

- **Never write a literal `${`.** Flux post-build substitution expands `${var}`
  and replaces an unknown one with an empty string. A bare `$var` — every Go
  template variable — is untouched. The single deliberate `${private_domain_name}`
  is a real key in both clusters' ConfigMaps.
- **Alertmanager ships no sprig.** There is no `default` and no arithmetic. A
  template calling one fails to execute, and Alertmanager then drops the
  notification silently.

`./scripts/validate-alertmanager-templates.sh` renders every templated string in
every rendered receiver against the fixtures, checks each rendered Alertmanager
config with `amtool check-config`, and asserts every VMAlert carries an absolute
`external.url`.

---

## References

- [prometheus/alertmanager#2217](https://github.com/prometheus/alertmanager/issues/2217) — Block Kit support, open since 2020
- [Monzo's Alertmanager Slack templates](https://gist.github.com/milesbxf/e2744fc90e9c41b47aa47925f8ff6512) — the vendored set this replaces
- [Notification template reference](https://prometheus.io/docs/alerting/latest/notifications/) — the function set available
- [Dashboards and alerts](../platform/observability/dashboards-and-alerts.md) — the annotation contract and the rendered example
