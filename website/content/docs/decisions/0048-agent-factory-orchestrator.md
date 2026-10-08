---
title: A custom Task controller with Kueue admission orchestrates the agent factory
linkTitle: 0048 · Factory orchestrator
weight: 480
description: The dark factory's orchestrator is a small Go controller reconciling a runtime-only Task CRD, with Kueue admitting sandboxes, chosen over Argo Workflows, Tekton, Temporal, a Crossplane XR and gh-aw.
lastVerified: 2026-10-01
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana
**Related Spec**: [SP3 dark factory](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md)

---

## Context

The dark factory turns triggers (a maintainer's issue label, RunLore findings, schedules) into
sequential agent runs that open a pull request, then watches CI, policy and humans for hours until
the PR merges, closes or is reverted. It must enforce three levels of token budget, honour a kill
switch, and be the only creator of `AgentRun`s so that a principal's daily budget has one
enforcement point.

---

## Decision Drivers

- The lifecycle is a reconciliation against GitHub state that lasts hours
- Budgets, caps and the kill switch are domain logic every option would still need
- No new stateful service: the cluster is rebuilt routinely
- Configuration in Git, state at runtime, audit through the room log that already records every run

---

## Considered Options

### Option 1: A custom controller and a `Task` CRD, Kueue for admission

**Pros**:
- Waiting on GitHub is a requeue; state lives in the CR; no database
- Budgets and the kill switch are first-class code, tested with envtest
- Kueue caps and drains sandbox pods independently of the factory

**Cons**:
- We own the code (one CRD, one config file, libraries)

### Option 2: Argo Workflows

**Pros**:
- DAGs, retries, semaphores, a UI and an archive

**Cons**:
- Long GitHub waits need suspend/resume or polling pods; a UI to secure; no budget concept

### Option 3: Tekton, Temporal, a Crossplane `Task` XR, or gh-aw

**Pros**:
- Tekton has GitHub interceptors; Temporal has durable timers; an XR matches `AgentRun`; gh-aw has "safe outputs"

**Cons**:
- Tekton is CI-shaped with no global queue; Temporal adds a server and a database; an XR has no
  timers, events or backoff; gh-aw runs on GitHub runners, outside the sandbox and identity design

---

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: Every alternative still needs the budget, cap and kill-switch logic written by us,
and each adds a component or loses the reconciliation model. A controller-runtime controller
reconciling `Task`s, shipped as a signed chart from `Smana/agent-platform` beside the room broker, is the smallest
thing that fits.

---

## Consequences

### Positive

- One Deployment with leader election; Tasks are inspectable with `kubectl`
- The factory is the single creator of runs, so the caps it checks before creating one hold. Its
  run meter revokes a run over its tier's `runTokens`; a gateway-side per-run ceiling arrives with
  SP4 PR 2 (ADR-0050), not yet built

### Negative

- Our code is on the critical path. Mitigated by envtest suites and by kill-switch layers that do
  not depend on the factory: the GitHub App today, Kueue from SP3 phase 4

### Neutral

- Tasks are runtime objects, never in Git, so the validation catalog is unaffected

---

## Implementation Notes

Code in [Smana/agent-platform](https://github.com/Smana/agent-platform) (the factory packages, the
`agent-factory` binary and chart); manifests in `tooling/base/agent-factory/`, an
`agent-platform` umbrella child on both clusters. Helm never upgrades a chart's `crds/`, so the
HelmRelease replaces the Task CRD on upgrade.

What phase 1 builds, against the decision above:

| Decided | Built today |
|---|---|
| Kueue admits and drains sandbox pods | Not deployed; it arrives with SP3 phase 4 (triage and teams). Until then the factory's own caps bound concurrency: 3 active tasks, 4 concurrent runs, 20 tasks a day |
| Three levels of token budget | The run budget only: the run meter revokes a run at its cap (`budget-run`). Task tokens are recorded, not enforced; the principal and fleet budgets follow |
| A kill switch | The `agent-factory-stop` ConfigMap stops everything; `factory/stop` stops one task |

---

## References

- [SP3 research](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-research.md#orchestrator)
- [Kueue ClusterQueue](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
