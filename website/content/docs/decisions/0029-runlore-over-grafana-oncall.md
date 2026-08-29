---
title: RunLore and Slack over Grafana OnCall
linkTitle: 0029 · RunLore over OnCall
weight: 290
description: Alert handling runs on the RunLore SRE agent plus a Slack channel rather than a self-hosted Grafana OnCall — whose upstream is archived, whose migration path is cloud-only, and whose in-repo deployment was fully built but never once wired into Flux.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-30
**Deciders**: Platform Team

---

## Context

This repository carried a complete Grafana OnCall deployment under
`observability/base/grafana-oncall/`: the `oncall` chart 1.16.5 (engine plus
Celery workers), a RabbitMQ `HelmRelease`, a `SQLInstance` and a `KVStore`
claim for its MySQL-compatible database and Valkey cache, four
`ExternalSecret`s, and two `HTTPRoute`s. It was never referenced by any Flux
Kustomization — every manifest was authored, none ever ran. What *did* run was
its residue: the `grafana-oncall-app` Grafana plugin, and a provisioning
ConfigMap pointing the plugin at an `oncall-engine:8080` Service that did not
exist.

Meanwhile the platform's actual incident flow grew up next to it. Alertmanager
routes every non-blackholed alert to the RunLore SRE agent's webhook —
auto-investigation, Slack posts with feedback and silence buttons — with
`continue: true`, so the same alert also lands in the Slack `#alerts` channel
formatted with the Monzo templates and runbook / query / dashboard / silence
action buttons. For a one-operator reference platform whose paging requirement
is "a human reads Slack", that *is* the whole incident flow.

Upstream then decided the question's urgency: Grafana OnCall OSS entered
maintenance mode on 2025-03-11, and the repository was archived on 2026-03-24 —
read-only, zero future patches of any severity. The official migration path is
Grafana Cloud IRM, which is cloud-only.

---

## Decision Drivers

- **Upstream viability.** An archived project receives no patches, including
  security patches, ever. Running it as an internet-era web app with a
  database, a message queue and a cache is a standing liability.
- **Footprint proportional to the requirement.** Engine + Celery + RabbitMQ +
  MySQL-compatible database + Valkey ≈ five standing workloads, for a platform
  operated by one person.
- **What already works.** The RunLore + Slack path is deployed, wired, and
  handling every alert today; OnCall never handled one.
- **Self-hosted stance.** The reference platform demonstrates self-hosted
  patterns; a cloud-only migration path is not an answer for it.

---

## Considered Options

### Option 1: RunLore SRE agent + Slack `#alerts` (the path already running)

**Pros**:
- Already carries the full flow: auto-investigation on every non-blackholed
  alert, Slack posts with feedback/silence buttons, Monzo-templated `#alerts`
  messages with runbook / query / dashboard / silence actions.
- Zero additional standing workloads — RunLore is deployed on both clusters
  anyway.
- No archived-upstream exposure.

**Cons**:
- No paging: no escalation policies, no phone/SMS/push notification chain.
- No on-call schedules or rotations.
- No dead-man's switch — nothing notices if the alerting pipeline itself dies
  (see [ADR-0031](0031-per-cluster-observability-panes.md) for the follow-up).

### Option 2: Wire up the built Grafana OnCall stack

Finish the job: add the directory to a Flux Kustomization and run what was
authored.

**Pros**:
- Real escalation chains, schedules, and mobile push — the features Option 1
  lacks.
- The manifests already existed; the marginal authoring cost was zero.

**Cons**:
- Upstream archived 2026-03-24: read-only, no patches of any severity, for a
  component that terminates webhooks and holds credentials.
- Five standing workloads (engine, Celery, RabbitMQ, MySQL-compatible DB,
  Valkey) to operate for a paging requirement that is "a human reads Slack".
- A dead end by construction — the vendor's own path off of it is cloud-only.

### Option 3: Grafana Cloud IRM (the official migration path)

**Pros**:
- Maintained, supported, and the vendor's designated successor.
- Real paging and schedules without operating any of it.

**Cons**:
- Cloud-only: a SaaS dependency for alert delivery on a reference platform
  demonstrating self-hosted patterns.
- Recurring cost for capabilities (rotations, escalations) a one-operator
  platform does not exercise.

---

## Decision Outcome

**Chosen option**: "Option 1 — RunLore + Slack"

**Rationale**: Option 2 fails on upstream viability alone — an archived
codebase is a security liability with no remediation path, and its five
standing workloads buy paging features the platform has no one to page.
Option 3 trades the archived-software problem for a cloud dependency that
contradicts the platform's self-hosted stance. Option 1 is not a compromise:
the RunLore webhook plus Slack channel already implements everything the
platform's single operator actually consumes, and it was doing so while the
OnCall manifests sat unwired.

---

## Consequences

### Positive

- Five standing workloads are not run, and an archived upstream is not
  operated.
- The incident flow is the one that was already proven: every non-blackholed
  alert is auto-investigated by RunLore and lands in Slack with actionable
  buttons.
- The never-wired estate stopped being a trap for readers: a complete-looking
  `grafana-oncall/` directory strongly implied a running service that did not
  exist.

### Negative

- **No paging or escalation policies, and no on-call schedules.** If the Slack
  message is not read, nothing escalates.
  - *Mitigation*: accepted for a one-operator reference platform; if
    multi-operator paging is ever needed, adopt a *maintained* alternative —
    do not resurrect the archived OnCall.
- **No dead-man's switch.** A dead alerting pipeline is currently
  indistinguishable from a quiet day; the `Watchdog` heartbeat is deliberately
  blackholed. This remains an open follow-up, recorded in
  [ADR-0031](0031-per-cluster-observability-panes.md).

### Neutral

- The unwired stack and its live residue were removed on 2026-08-30: the
  `observability/base/grafana-oncall/` directory, the `grafana-oncall-app`
  plugin, the provisioning ConfigMap pointing at the nonexistent
  `oncall-engine:8080`, and the secret-store seeds.

---

## Implementation Notes

Removal only — the chosen option was already deployed. The Alertmanager
routing lives in
`observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`:
a `runlore` webhook receiver with `continue: true` ahead of the
`slack-monitoring` receiver, authenticated with a bearer token from the
`runlore-webhook-token` secret. RunLore itself is `observability/base/runlore/`
plus per-cluster overlays.

---

## References

- [Grafana OnCall maintenance-mode announcement](https://grafana.com/blog/2025/03/11/grafana-oncall-maintenance-mode/)
  (2025-03-11); repository archived 2026-03-24
- [ADR-0031](0031-per-cluster-observability-panes.md) — where alerts terminate,
  and the missing dead-man's switch
- `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml`
  — the Alertmanager route: blackhole matcher, RunLore receiver with
  `continue: true`, Slack receiver
- `observability/base/runlore/` — the RunLore deployment
