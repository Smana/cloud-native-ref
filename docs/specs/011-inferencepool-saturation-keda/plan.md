# Plan: Opt-in InferencePool saturation autoscaling (KEDA)

**Spec**: [SPEC-011](spec.md)
**Status**: draft
**Last updated**: 2026-07-18

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation. Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

New optional claim field (default keeps today's behavior):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen3-8b
  namespace: llm
spec:
  gateway:
    endpointPicker:
      enabled: true          # existing (SPEC-004) — gates the whole feature
  scaling:
    saturationThreshold: "0.8"   # NEW, optional; only used when endpointPicker.enabled
```

Rendered `ScaledObject` (when `endpointPicker.enabled`) gains a 4th trigger appended to the existing three:

```yaml
- type: prometheus
  metadata:
    serverAddress: http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428
    query: 'max(inference_pool_<saturation_gauge>{...="<name>"})'   # exact name TBD (FR-005)
    threshold: "<saturationThreshold>"        # default from spec.scaling
    activationThreshold: "0.05"
```

### Resources Created

| Resource | Condition | Notes |
|----------|-----------|-------|
| 4th KEDA trigger on the `ScaledObject` | When `endpointPicker.enabled` | OR-combined with the 3 existing (FR-007) |
| (no new scrape) | — | EPP `VMServiceScrape` (`main.k:726-737`) already scrapes the gauge when EPP on |

No new standalone Kubernetes objects — this is an additive trigger inside the existing per-claim `ScaledObject`.

### Key Entities

- **`ScaledObject`** (`main.k:522-570`): one per `InferenceService`; today 3 triggers, gains a 4th when EPP on.
- **EPP (`<name>-epp`)**: the only emitter of the pool saturation gauge; rendered only when `endpointPicker.enabled` (SPEC-004 HelmRelease `main.k:670-720` + `VMServiceScrape` `main.k:726-737`).

### Dependencies

- [ ] **EPP running for the model** — hard dependency. The gauge exists only when `spec.gateway.endpointPicker.enabled` (SPEC-004, opt-in, default-off). See [CL-1](clarifications.md).
- [ ] EPP `VMServiceScrape` feeding the gauge into VictoriaMetrics (already rendered by SPEC-004 when EPP on).
- [ ] Exact v1.5.0 saturation gauge metric name confirmed (spec Open questions / T001).

### Alternatives considered

**Make the EPP a fleet-wide prerequisite** (turn it on everywhere, saturation gauge becomes the primary signal) — rejected in [CL-1](clarifications.md): larger blast radius, forces dropping `canaries[]` on `qwen-coder`, and SPEC-004 is still draft. **Replace the raw triggers entirely for EPP models** — deferred (FR-007): ADD first, validate (SC-003), then consider replacing. **Defer the whole spec until SPEC-004 GA** — rejected: the gated design is cheap and lets us validate the signal on the first EPP-enabled model.

---

## Implementation Notes

- **Insertion point**: append a 4th trigger dict in the `triggers` list at `main.k:532-567` (after L566), wrapped in an `if _endpointPickerEnabled` conditional. Add `_saturationThreshold` default near `main.k:39-45`. Expose `spec.scaling.saturationThreshold` in `inference-service-definition.yaml` (scaling block ~L25).
- **No KCL dict mutation** (function-kcl #285): build the triggers list with a single-line comprehension / inline conditional append, not by mutating the list after creation.
- **Reuse the gate variable** the composition already computes for `endpointPicker` (the same switch that flips `_baseRuleBackendRefsFor` to the InferencePool backend, `main.k:355-357`) — do not introduce a second source of truth.
- **Metric name is unverified** — `main.k` and the gateway dashboard reference `inference_pool_average_*`; the *pool-wide saturation* gauge (v1.5.0) is new and not yet in the repo. T001 must pin the exact name before wiring the query.

### File structure

```
infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k            # 4th trigger (gated) + _saturationThreshold default
├── main_test.k       # 4-triggers-when-EPP / 3-when-not assertions
└── inference-service-definition.yaml   # spec.scaling.saturationThreshold field
```

### Validation path

- `kcl fmt` passes; `./scripts/validate-kcl-compositions.sh` → exit 0
- `crossplane render` on an EPP-on example (4 triggers) and an EPP-off example (3 triggers)
- `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`

---

## Tasks

> Each task has a stable ID. Cite fresh evidence before marking `[x]` (see [.claude/rules/process.md](../../../.claude/rules/process.md)).

> **Requirements coverage**: FR-001 → T003; FR-002 → T003/T005; FR-003 → T003; FR-004 → T005; FR-005 → T001; FR-006 → T001/T002; FR-007 → Design (ADD not replace); FR-008 → T004.

### Phase 1: Prerequisites

- [ ] **T001**: Confirm the exact v1.5.0 pool saturation gauge metric name + PromQL from the EPP `/metrics` (resolves spec Open question 1); pick a conservative default `saturationThreshold` (Open question 2).

### Phase 2: Implementation

- [ ] **T002**: Add `spec.scaling.saturationThreshold` to `inference-service-definition.yaml` (optional, defaulted).
- [ ] **T003**: Add `_saturationThreshold` default (`main.k:~39-45`) and append the gated 4th trigger (`main.k:532-567`), reusing the existing `endpointPicker` gate variable.

### Phase 3: Validation & Documentation

- [ ] **T004**: `main_test.k` asserts 4 triggers with EPP on, 3 with EPP off (SC-001, SC-004).
- [ ] **T005**: `crossplane render` — EPP-on example renders 4 triggers; EPP-off example diff vs pre-change is empty.
- [ ] **T006**: `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`.
- [ ] **T007**: Live validation on the first EPP-enabled model — gauge present in VictoriaMetrics (SC-002), scales up under load (SC-003). *(Deferred to cluster availability.)*
- [ ] **T008**: README / settings-example note the opt-in saturation trigger + its EPP dependency.

### Deviations from plan

<!-- Append as surprises show up. -->

---

## Review Checklist

### Project Manager

- [ ] Problem statement is clear and specific
- [ ] User stories capture real user needs
- [ ] Acceptance scenarios are testable
- [ ] Scope is well-defined (goals AND non-goals)
- [ ] Success criteria are measurable

### Platform Engineer

- [ ] Design follows existing patterns (`inference-service` ScaledObject rendering, SPEC-001)
- [ ] API consistent with the existing `spec.scaling` block
- [ ] KCL avoids mutation pattern (function-kcl #285); trigger append is single-line/inline-conditional
- [ ] Reuses the existing `endpointPicker` gate variable (no second source of truth)
- [ ] Examples provided (EPP-on + EPP-off)

### Security & Compliance

- [ ] No new network surface — reuses EPP `VMServiceScrape` (already CNP-scoped to vmagent, `main.k:320-329`)
- [ ] No new credentials
- [ ] No RBAC change (trigger lives in the existing `ScaledObject`; `scaledobjects` already granted, `additional-rbac.yaml:149`)

### SRE

- [ ] Metric sourced from VictoriaMetrics (same `serverAddress` as existing triggers)
- [ ] No scale-to-zero (min ≥ 1, per SPEC-001's min=1 default)
- [ ] Failure mode: EPP down → gauge stale → trigger contributes nothing, raw triggers still scale (safe degradation)
- [ ] Rollback: remove the field / set `endpointPicker.enabled: false` → reverts to 3 triggers

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Depends on: [SPEC-004](../004-per-inferenceservice-inferencepool-endpoint/spec.md)
- Builds on: [SPEC-001](../0001-llm-platform-prometheus-autoscaling/spec.md)
