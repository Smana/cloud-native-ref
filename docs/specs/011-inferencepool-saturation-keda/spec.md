# Spec: Opt-in InferencePool saturation autoscaling (KEDA)

**ID**: SPEC-011
**Issue**: [#1636](https://github.com/Smana/cloud-native-ref/issues/1636)
**Status**: draft
**Type**: composition
**Created**: 2026-07-18
**Last updated**: 2026-07-18

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Add an **opt-in** fourth KEDA trigger to the `inference-service` composition that scales a vLLM model on the **InferencePool saturation gauge** emitted by the EndpointPicker (EPP, Gateway API Inference Extension v1.5.0), **gated on `spec.gateway.endpointPicker.enabled`**. Models without the EPP keep today's three vLLM-raw triggers unchanged. This layers cleanly on top of the (default-off) EPP from [SPEC-004](../004-per-inferenceservice-inferencepool-endpoint/spec.md) — it does **not** force the EPP on.

---

## Problem

Today the composition scales every vLLM model on **three OR-combined vLLM-raw Prometheus triggers** (`kcl/inference-service/main.k:532-567`): running-ratio (`vllm:num_requests_running / maxNumSeqs`, threshold 0.7), KV-cache (`vllm:kv_cache_usage_perc`, 0.6), and queue-depth (`vllm:num_requests_waiting`, 8). Two problems:

1. **The KV-cache trigger is dead weight on L4 GPUs.** [SPEC-001](../0001-llm-platform-prometheus-autoscaling/spec.md) records (its inert-cache-trigger finding) that with `maxNumSeqs=32` the running-ratio trigger always fires first, so the cache trigger is never practically exercised — three triggers where one is inert.
2. When the **EPP** is enabled (SPEC-004), the Inference Extension v1.5.0 EPP emits a **pool-level saturation gauge** (plus inflight-token saturation) that could be a cleaner *single* leading signal than three raw per-replica metrics. But that gauge **only exists when the EPP runs** — there is no independent pool controller emitting it, and the EPP is opt-in, default-off, and enabled on **zero models today**.

We want an opt-in path to scale on the pool saturation signal for EPP-enabled models, **without** forcing an EPP rollout and **without** changing autoscaling for the (majority) non-EPP models.

---

## User Stories

### US-1: Cleaner pool-level scaling signal for EPP-enabled models (Priority: P1)

As a **platform user running a model with `endpointPicker.enabled: true`**, I want KEDA to scale on the InferencePool saturation gauge, so that autoscaling uses a single pool-level leading signal instead of three raw vLLM metrics (one of which is inert on our GPUs).

**Acceptance Scenarios**:
1. **Given** a claim with `spec.gateway.endpointPicker.enabled: true`, **When** the composition renders the `ScaledObject`, **Then** it contains a fourth Prometheus trigger querying the InferencePool saturation gauge.
2. **Given** that model under load, **When** pool saturation crosses the threshold, **Then** KEDA scales the model Deployment up.

### US-2: Non-EPP autoscaling is unchanged (Priority: P1)

As a **platform user not using the EPP**, I want autoscaling to be byte-identical to today (running-ratio + KV-cache + queue), so that this change is non-breaking and strictly opt-in.

**Acceptance Scenarios**:
1. **Given** a claim without `endpointPicker` (or `enabled: false`), **When** the composition renders, **Then** the `ScaledObject` has exactly the three existing triggers and the rendered diff vs pre-change is empty.

### US-3: The saturation trigger is validated before trust (Priority: P2)

As a **platform maintainer**, I want the saturation trigger validated against real EPP metrics on a live cluster before we consider it a replacement for the raw triggers, so we don't regress scaling behavior.

**Acceptance Scenarios**:
1. **Given** an EPP-enabled model on a live cluster, **When** I query VictoriaMetrics for the saturation gauge, **Then** it returns data, and under load the trigger scales up before/comparably to running-ratio.

---

## Requirements

### Functional

- **FR-001**: When `spec.gateway.endpointPicker.enabled` is true, the composition MUST render an additional KEDA Prometheus trigger sourced from the InferencePool saturation gauge, appended to the existing triggers (`main.k:532-567`).
- **FR-002**: When `endpointPicker` is absent or false, the `ScaledObject` MUST render exactly today's three triggers — **no change** (opt-in, default-off).
- **FR-003**: The saturation trigger MUST use the same `serverAddress` as the existing triggers — `http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428` (`main.k:108`).
- **FR-004**: The metric MUST be scraped by the EPP `VMServiceScrape` already rendered when `endpointPicker` is on (`main.k:726-737`); no new scrape config is required for EPP-enabled models.
- **FR-005**: The exact saturation gauge metric name + PromQL MUST be confirmed against the GAIE v1.5.0 EPP `/metrics` output before implementation (repo dashboard already references the `inference_pool_*` naming family: `inference_pool_average_kv_cache_utilization`, `inference_pool_average_queue_size`).
- **FR-006**: The saturation threshold MUST be claim-overridable via a new `spec.scaling.saturationThreshold` field with a conservative default; the trigger MUST also set an `activationThreshold` consistent with the min=1 design.
- **FR-007**: The new trigger MUST **add to** (OR-combine with) the existing triggers initially, not replace them — replacing raw triggers for EPP models is deferred to a follow-up after empirical validation (US-3).
- **FR-008**: `main_test.k` MUST assert **4** triggers when `endpointPicker` is on and **3** when off (`main_test.k:96-101`).

### Non-Goals

- **Not** turning the EPP on by default — it stays SPEC-004 opt-in, default-off.
- **Not** removing the three existing triggers for non-EPP models.
- **Not** making the EPP a fleet-wide prerequisite (rejected — see [CL-1](clarifications.md)).
- **Not** forcing `qwen-coder` (or any `canaries[]` model) off canaries — the EPP is CEL-mutually-exclusive with `canaries[]`, so those models simply don't get the new trigger.
- **Not** fixing the pre-existing `num_requests_waiting` trigger inconsistency (code `main.k:562` re-added it despite SPEC-001 CL-1 dropping it) — flagged for a **separate** cleanup PR.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must answer yes/no with cluster evidence.

- **SC-001**: A claim with `endpointPicker.enabled: true` renders a `ScaledObject` with **4** triggers; a claim without it renders **3** — verified via `crossplane render` + `main_test.k`.
- **SC-002**: On a live cluster with an EPP-enabled model, the saturation gauge metric is present in VictoriaMetrics (query returns non-empty data).
- **SC-003**: Under load, the saturation trigger scales the model up before or comparably to the running-ratio trigger — evidence: KEDA/HPA scale events + the two metrics' timeseries.
- **SC-004**: A non-EPP model's rendered `ScaledObject` is **byte-identical** to pre-change (empty diff).
- **SC-005**: No scale-to-zero — `minReplicaCount` stays ≥ 1 for all models (consistent with SPEC-001's min=1 default).

---

## Open questions

<!-- Resolved via /clarify → appended to clarifications.md as CL-N. -->

- [ ] [NEEDS CLARIFICATION: Exact v1.5.0 saturation gauge metric name + PromQL — verify from the EPP source/`/metrics` (candidate family `inference_pool_*`; the *pool-wide saturation* gauge name is not yet referenced anywhere in the repo).]
- [ ] [NEEDS CLARIFICATION: Default value for `spec.scaling.saturationThreshold` — needs empirical tuning; start conservative.]
- [ ] [NEEDS CLARIFICATION: Long-term, should the saturation trigger REPLACE the raw triggers for EPP models (cleaner single signal) rather than OR-combine? Deferred to a follow-up after SC-003 validation — FR-007 keeps ADD for now.]

<!-- Resolved: CL-1 — gate the new trigger on the EPP (opt-in), do not force EPP rollout. -->

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Depends on: [SPEC-004 — per-InferenceService InferencePool + EPP](../004-per-inferenceservice-inferencepool-endpoint/spec.md) (opt-in, default-off)
- Builds on: [SPEC-001 — LLM platform Prometheus autoscaling](../0001-llm-platform-prometheus-autoscaling/spec.md) (its lagging-signal + inert-cache-trigger decisions)
- Composition: `infrastructure/base/crossplane/configuration/kcl/inference-service/main.k`
- EPP metrics precedent: `apps/base/ai/llm/grafana-dashboard-gateway.yaml`
