# Spec: InferenceService v0.8.0: spec.engineArgs escape hatch with reserved-flag CEL denylist and structured status.servedModels

**ID**: SPEC-003
**Issue**: [#1569](https://github.com/Smana/cloud-native-ref/issues/1569)
**Status**: draft
**Type**: composition
**Created**: 2026-07-11
**Last updated**: 2026-07-11

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Add an optional `spec.engineArgs: []string` escape hatch to the InferenceService composition (KCL module v0.8.0) that appends verbatim vLLM CLI flags after all composition-managed flags, guarded by XRD CEL rules that reject-at-admission any flag the composition already owns; and expose a structured `status.servedModels` list (base + LoRA adapters + canary weights) so the served-model topology is discoverable from the XR itself.

---

## Problem

Every time a model needs a vLLM flag the composition doesn't already emit — `--rope-scaling`, `--enforce-eager`, `--kv-cache-dtype`, `--speculative-config`, and the long tail of vLLM engine tuning — a platform user is blocked on an XRD + composition release: a Modelplane-style API review (arrays over objects, enums, no new required fields for forward-compat), a `kcl.mod` version bump, an OCI publish, and a composition pin bump. That round-trip is disproportionate to "pass one more flag to vLLM". Yet the composition cannot simply forward arbitrary flags blindly: a handful of flags are *load-bearing* — `--served-model-name` and `--max-num-seqs` feed KEDA (the running/`maxNumSeqs` ratio is the scale-up trigger's denominator) and the gateway pin/canary rules (which match on the served model name). If a user overrode those through a raw-args field, the autoscaler denominator and the AI-Gateway routing would silently diverge from what the composition believes it deployed.

Separately, once a claim carries LoRA adapters and gateway canaries (SPEC-002), there is no machine-readable answer to "what model names does this claim actually serve, and how is base-model traffic split?" — it can only be reconstructed by reading the spec and cross-referencing the rendered `AIGatewayRoute`. ML users and dashboards need that answer on the XR itself.

Now: SPEC-002 (PR #1559) just landed composition-owned gateway routing with `gateway.canaries[]`; the served-model topology it produces is exactly what `status.servedModels` should surface, and it is the natural moment to add the escape hatch before the module's v0.x API ossifies.

---

## User Stories

### US-1: Pass a new vLLM flag without a composition release (Priority: P1)

As a **platform user deploying a model**, I want **to append arbitrary vLLM engine flags to a claim**, so that **I can adopt a new vLLM tuning knob the same day without waiting on an XRD + composition release cycle**.

**Acceptance Scenarios**:
1. **Given** a claim with `spec.engineArgs: ["--rope-scaling", "--enforce-eager"]`, **When** the composition renders, **Then** the vLLM container `args` end with `--rope-scaling` then `--enforce-eager`, after every composition-managed flag, in the order written.
2. **Given** a claim with `spec.engineArgs: ["--kv-cache-dtype=fp8"]` (single-token `--flag=value` form), **When** the composition renders, **Then** that single token appears verbatim as one element of the container `args`.
3. **Given** a claim with no `spec.engineArgs`, **When** the composition renders, **Then** the container `args` are byte-identical to v0.7.x (no regression).

### US-2: Fail fast on a composition-managed flag (Priority: P1)

As the **platform maintainer**, I want **the API server to reject any engineArgs entry that collides with a flag the composition manages**, so that **the KEDA scaling denominator and the gateway served-model names stay trustworthy and there is never spec-vs-runtime drift**.

**Acceptance Scenarios**:
1. **Given** a claim with `spec.engineArgs: ["--max-num-seqs=256"]`, **When** it is applied, **Then** the API server rejects it at admission with a message naming the curated field to use instead (`spec.model.maxNumSeqs`).
2. **Given** a claim with `spec.engineArgs: ["--served-model-name=foo"]`, **When** it is applied, **Then** it is rejected at admission pointing at the claim name as the served-model source.
3. **Given** a claim with `spec.engineArgs: ["--enable-lora"]`, **When** it is applied, **Then** it is rejected at admission pointing at `spec.loraAdapters`.

### US-3: Reject the two-token form (Priority: P2)

As the **platform maintainer**, I want **every engineArgs entry to be required to start with `--`**, so that **the ambiguous two-token `--flag value` form is structurally impossible and the reserved-flag denylist stays a simple per-entry prefix match**.

**Acceptance Scenarios**:
1. **Given** a claim with `spec.engineArgs: ["--tensor-parallel-size", "2"]` (the bare `2` is a second token), **When** it is applied, **Then** it is rejected at admission because `2` does not start with `--` (the user must write `--tensor-parallel-size=2`).

### US-4: Discover the served-model topology (Priority: P1)

As an **ML user (and dashboard/UI author)**, I want **the claim's status to list every model name it serves and any canary weight**, so that **I can see the base model, its adapters, and traffic splits without reading the composition internals or the rendered gateway route**.

**Acceptance Scenarios**:
1. **Given** a claim `xplane-qwen-coder` with `loraAdapters: [{name: xplane-qwen-coder-sql-dpo, ...}]` and `gateway.canaries: [{adapter: xplane-qwen-coder-sql-dpo, weightPercent: 10}]`, **When** it reconciles, **Then** `status.servedModels` contains `{name: xplane-qwen-coder, kind: base}` and `{name: xplane-qwen-coder-sql-dpo, kind: adapter, canaryWeightPercent: 10}`.
2. **Given** the same claim, **When** I run `kubectl get inferenceservice`, **Then** an additional printer column shows the served model names.
3. **Given** a claim with adapters but no canaries, **When** it reconciles, **Then** each adapter entry has `kind: adapter` and NO `canaryWeightPercent` field.

---

## Requirements

### Functional

- **FR-001**: The XRD MUST add an optional `spec.engineArgs` field of type `array` of `string` (`maxItems: 16` — CL-4). Absent/empty MUST render exactly as v0.7.x (no behavioural change when unset).
- **FR-002**: The composition MUST append `spec.engineArgs` entries verbatim to the vLLM container `args`, **after** all composition-managed flags (`_baseVllmArgs` + quant + prefix-cache + kv-offload + tool-call + lora), preserving the user's order (CL-4). The last-wins semantics of duplicate vLLM flags means composition-managed flags always precede user flags — but reserved flags are already denied at admission (FR-003), so no managed flag is ever duplicated.
- **FR-003**: XRD CEL validation MUST reject at admission (NOT composition-wins-silently, NOT reject-at-render — CL-1) any `engineArgs` entry whose flag token collides with a composition-managed flag. The reserved list and the enforcement semantics are: match the entry's flag token (the substring before `=`, or the whole entry) against the reserved set. Each rejection message MUST name the curated field to use instead. The reserved set (derived from `main.k`, see plan.md) is: `--model`, `--served-model-name`, `--max-model-len`, `--max-num-seqs`, `--gpu-memory-utilization`, `--quantization`, `--enable-prefix-caching`, `--cpu-offload-gb`, `--enable-auto-tool-choice`, `--tool-call-parser`, `--enable-lora`, `--max-loras`, `--max-lora-rank`, `--lora-modules`, plus the serving-contract flags `--port` and `--host` (both fixed at the composition's 8000/default and relied on by the Service, probes, and gateway Backend — CL-1).
- **FR-004**: XRD CEL validation MUST reject at admission any `engineArgs` entry that does not start with `--` (CL-4). This makes the two-token `--flag value` form structurally impossible and keeps the reserved-flag check a per-entry prefix match.
- **FR-005**: The composition MUST populate `status.servedModels` as a list of objects `{name: string, kind: "base"|"adapter", canaryWeightPercent?: int}`, computed purely from `spec` and existing gateway state (no new observed resources): exactly one `kind: base` entry whose `name` is the claim's served model name (the claim name); one `kind: adapter` entry per `spec.loraAdapters[]` with `name` = that adapter's `loraAdapters[].name` verbatim; and `canaryWeightPercent` present ONLY on adapter entries that a `gateway.canaries[]` entry targets, set to that entry's `weightPercent` (FR-005 mirrors the routing SPEC-002 renders).
- **FR-006**: The XRD MUST add an `additionalPrinterColumns` entry surfacing the served model names from `status.servedModels`.
- **FR-007**: `status.phase` and `status.modelEndpoint` MUST be unchanged (SPEC-002 behaviour preserved).

### Non-Goals

- Validating that an `engineArgs` flag is a *real* vLLM flag or that its value is well-typed — vLLM owns that; a bad flag fails at container start, observable via logs/CrashLoopBackOff (documented failure mode). The escape hatch only guarantees it does not collide with the composition.
- Deduplicating or reordering user-supplied `engineArgs` among themselves.
- Multi-token quoted values or shell-style args parsing — single-token `--flag[=value]` only (CL-4).
- Surfacing per-model *readiness* or per-adapter load status in `status.servedModels` (it is a topology list, not a health list); health stays on `status.phase` and the Deployment/route readiness gates.
- Changing any composition-managed flag's curated field, defaults, or KEDA/gateway wiring.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: A claim with `spec.engineArgs: ["--enforce-eager", "--kv-cache-dtype=fp8"]` renders a vLLM container whose `args` list ends with exactly those two tokens, in that order, immediately after the last composition-managed flag — verified in `crossplane render` output and a `main_test.k` assertion.
- **SC-002**: A claim with `spec.engineArgs: ["--max-num-seqs=256"]` is rejected at `kubectl apply` (and Flux dry-run) with a CEL message containing the string `spec.model.maxNumSeqs`.
- **SC-003**: A claim with `spec.engineArgs: ["--tensor-parallel-size", "2"]` is rejected at admission with a CEL message about the `--` prefix requirement.
- **SC-004**: On the `xplane-qwen-coder` claim (adapters + a 10% sql-dpo canary), `kubectl get inferenceservice xplane-qwen-coder -o json | jq .status.servedModels` returns the base entry plus one adapter entry per `loraAdapters[]`, with `canaryWeightPercent: 10` on the sql-dpo adapter and no such field on non-canary adapters — and those names match the `x-ai-eg-model` match values and `modelNameOverride` values in the rendered `AIGatewayRoute`.
- **SC-005**: `kubectl get inferenceservice` shows a served-models printer column populated from `status.servedModels`.
- **SC-006**: `./scripts/validate-kcl-compositions.sh` exits 0; `main_test.k` covers: engineArgs appended last; managed-flags-still-win ordering; empty engineArgs = no-arg-change; servedModels base-only, base+adapters, base+adapter+canary shapes; and the existing 31 tests still pass with no regression.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

_None — all known unknowns resolved as CL-1…CL-4 below._

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — Enforcement semantics: reject-at-admission (not composition-wins-silently, not reject-at-render).
- CL-2 — `status.servedModels` shape: structured objects, not a plain string list.
- CL-3 — Sequencing: follow-up PR after #1559 merges; branch stacked for numbering + `canaries[]` context.
- CL-4 — engineArgs token form: single-token `--flag[=value]` only, CEL-enforced `--` prefix; `maxItems: 16`.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar spec: [SPEC-002 — Composition-owned AI Gateway routing](../002-composition-owned-gateway-routing/spec.md)
- Composition (this module, v0.7.0): `infrastructure/base/crossplane/configuration/kcl/inference-service/`
- vLLM engine args reference: <https://docs.vllm.ai/en/stable/configuration/engine_args.html>
