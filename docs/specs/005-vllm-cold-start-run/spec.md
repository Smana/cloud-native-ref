# Spec: vLLM cold-start reduction — Run:ai Model Streamer load-format for InferenceService

**ID**: SPEC-005
**Issue**: [#1571](https://github.com/Smana/cloud-native-ref/issues/1571)
**Status**: draft
**Type**: composition
**Created**: 2026-07-12
**Last updated**: 2026-07-12

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Add an opt-in `spec.model.streaming` block to the `InferenceService` composition that makes vLLM load model weights with NVIDIA's Run:ai Model Streamer (`--load-format runai_streamer`) instead of the default HuggingFace/safetensors loader. Streamer reads the *existing* `/models/<revision>` safetensors from the shared `llm-models` PVC concurrently and streams tensors straight to GPU, cutting the pod-ready → first-token cold-start window with no change to weight storage, the preload Job, autoscaling, or gateway routing. This is **phase 1** of the cold-start effort: the load-time win over the local filesystem path. Direct `s3://` streaming (which would eliminate the preload Job) and dynamic S3 LoRA resolution (which requires a vLLM image bump) are explicit non-goals here — see [`plan.md`](plan.md) *Alternatives* and CL-2/CL-4.

---

## Problem

vLLM cold-start dominates the scale-from-zero latency the KEDA autoscaler (SPEC-001) trades against cost. On a scale-up, a fresh GPU pod must load multi-gigabyte safetensors from the `llm-models` PVC (Amazon S3 Files, EFS-CSI-mounted) into GPU memory before it can serve a single token. The default vLLM loader reads shards sequentially and single-threaded, so this load phase takes minutes on the larger fleet models — every scale-from-zero request and every KEDA-driven replica add pays that tax, undermining the `min=1`→saturation-triggered scaling design. Nothing in the current composition addresses load throughput: the preload Job (composition-rendered, `huggingface-cli download --max-workers 1` to avoid the NFS filelock deadlock) only gets bytes onto the PVC; the *read-into-GPU* step is untouched. NVIDIA's Run:ai Model Streamer reads safetensors concurrently in chunks and streams them to GPU during load, a benchmarked path to vLLM-ready in ~23 s. The `vllm/vllm-openai:v0.8.5` image already bundles the streamer (CL-1), so the load-time win is available today as a flag — but there is no way to enable it per claim, and the flag would collide with the SPEC-003 `engineArgs` denylist if a user tried to pass it by hand.

---

## User Stories

### US-1: Opt into faster weight loading (Priority: P1)

As a **platform user deploying a model**, I want **a single flag on the InferenceService claim that switches weight loading to the Run:ai Model Streamer**, so that **a scaled-up or scaled-from-zero replica reaches first-token faster without me touching storage, the preload Job, or raw engine args**.

**Acceptance Scenarios**:
1. **Given** a claim with `model.streaming.enabled: true`, **When** the composition renders, **Then** the vLLM container args contain `--load-format runai_streamer` and the model path stays the existing local `/models/<revision>` (no storage change).
2. **Given** the same claim with `model.streaming.concurrency: 16`, **When** the composition renders, **Then** a `--model-loader-extra-config` arg carries `{"concurrency":16}` (CL-3).
3. **Given** a claim with `model.streaming.enabled` unset (default), **When** the composition renders, **Then** the vLLM args are byte-identical to the pre-SPEC-005 render — no streamer flags, no reordering (SC-004).

### US-2: Streaming flags stay composition-owned (Priority: P1)

As the **platform maintainer**, I want **`--load-format` and `--model-loader-extra-config` reserved by the composition**, so that **a user cannot pass them through the `spec.engineArgs` escape hatch and desync them from the `streaming` block**.

**Acceptance Scenarios**:
1. **Given** a claim with `engineArgs: ["--load-format", "runai_streamer"]`, **When** the claim is applied, **Then** the API server rejects it at admission (SPEC-003 CEL denylist names the reserved flag).
2. **Given** a claim with `engineArgs: ["--model-loader-extra-config", "{}"]`, **When** the claim is applied, **Then** it is rejected identically.

### US-3: Measure the cold-start win (Priority: P2)

As an **SRE**, I want **a before/after cold-start measurement on a fleet model**, so that **the streamer win is a recorded number, not a claim**.

**Acceptance Scenarios**:
1. **Given** one fleet model deployed with streaming off then on, **When** a scaled-from-zero pod starts, **Then** the pod-ready → first-token duration with streaming on is recorded and lower than with it off (SC-005).

---

## Requirements

### Functional

- **FR-001**: The `InferenceService` XRD MUST expose an optional `spec.model.streaming` block with `enabled` (bool, default `false`) and `concurrency` (int, optional). Default MUST be off (opt-in) — an unset block renders no streamer flags (CL-4).
- **FR-002**: When `spec.model.streaming.enabled` is true, the composition MUST add `--load-format runai_streamer` to the vLLM container args, keeping the model reference on the existing local `/models/<revision>` path (no `s3://` URL, no storage change) — CL-2.
- **FR-003**: When `spec.model.streaming.concurrency` is set, the composition MUST add `--model-loader-extra-config` carrying a JSON object with the `concurrency` key set to that value (CL-3). When unset, no `--model-loader-extra-config` arg is rendered.
- **FR-004**: `--load-format` and `--model-loader-extra-config` MUST be added to the SPEC-003 `engineArgs` CEL denylist AND to its `main_test.k` lockstep canonical list, so they cannot be passed via the escape hatch and the denylist/test stay in sync (CL-5).
- **FR-005**: With `spec.model.streaming.enabled` false or unset, the rendered vLLM args MUST be byte-identical to the pre-SPEC-005 output — no new flags, no reordering, no whitespace change (SC-004).
- **FR-006**: The composition MUST NOT introduce any new pod, container, init container, IAM role, S3 bucket, PVC, or Secret. The change is vLLM-arg (and denylist) only — the streamer binary is already present in `vllm/vllm-openai:v0.8.5` (CL-1) and reads the existing PVC-mounted safetensors.
- **FR-007**: The composition MUST NOT change KEDA `ScaledObject`, HPA, gateway (`AIGatewayRoute`/`AIServiceBackend`/`Backend`), preload Job, or `loraAdapters` rendering. Enabling streaming produces an args-only diff on the serving Deployment (SC-006).

### Non-Goals

- **Direct `s3://` streaming** that bypasses the PVC + preload Job (Model Streamer reading weights straight from a plain S3 bucket). This needs a plain S3 bucket (weights live in an S3 Files *filesystem*, not a plain bucket), an EPI IAM role, and CNP egress to S3 — a larger, higher-risk change deferred to a follow-up spec (CL-2).
- **Dynamic S3 / filesystem LoRA resolver plugin** (`lora_filesystem_resolver`, request-time adapter fetch). The built-in filesystem resolver ships in vLLM **v0.9.0**, not the current v0.8.5, and requires `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True` — an image bump plus a runtime-LoRA trust-boundary change. Descoped to a follow-up; static `--lora-modules` (SPEC-002 CL-5) and canary routing stay the source of truth (CL-4).
- **vLLM image bump.** Phase 1 stays on `vllm/vllm-openai:v0.8.5` because the streamer is already bundled (CL-1). Any bump is out of scope precisely because it affects all four fleet models, not just opt-in claims (CL-6).
- **Flipping `streaming.enabled` to default-true.** That is an e2e-gated follow-up once SC-005 has a measured win across the fleet (CL-4).
- **Streamer tunables beyond `concurrency`** (`memory_limit`, `distributed`, `pattern` in `--model-loader-extra-config`). Not exposed in v1; add on demand.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: A claim with `model.streaming.enabled: true` renders a serving Deployment whose vLLM container args include the exact tokens `--load-format` `runai_streamer`, verified via `crossplane render` / `kubectl get deploy -o json | jq` on the container `args`.
- **SC-002**: A claim with `model.streaming: {enabled: true, concurrency: 16}` renders a `--model-loader-extra-config` arg whose JSON value parses to an object with `concurrency == 16` (`jq` on the arg following the flag).
- **SC-003**: A claim passing `--load-format` or `--model-loader-extra-config` via `spec.engineArgs` is rejected at admission with a CEL message naming the reserved flag; `main_test.k`'s denylist lockstep test asserts both flags are in the canonical reserved list.
- **SC-004**: With `streaming` unset, `crossplane render` output for a representative fleet claim is byte-identical (diff empty) to the render on the pre-SPEC-005 module version — proving off-by-default is a no-op.
- **SC-005**: On one fleet model, the measured pod-ready → first-token duration (scaled-from-zero) with streaming enabled is recorded and strictly lower than the same measurement with streaming disabled; both numbers appear in the composition README.
- **SC-006**: Enabling `streaming` on a live claim produces a Deployment diff limited to the vLLM container `args` (no change to replicas, KEDA `ScaledObject`, gateway resources, preload Job, PVC, or Secrets), verified with `kubectl diff` / `git diff` on the rendered manifests; `hubble observe --verdict DROPPED` on the serving pod stays clean.
- **SC-007**: `./scripts/validate-kcl-compositions.sh` exits 0 and `main_test.k` covers: streamer flag present when enabled, absent when disabled, `concurrency` → extra-config JSON, off-by-default byte-identity, and the grown denylist lockstep list (Polaris ≥ 85).

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] Observation (non-blocking, resolved during T009 e2e): does Run:ai Model Streamer over the *local* PVC path yield a materially lower cold-start than the default loader (NVIDIA's ~23 s benchmark is quoted for S3; the local-filesystem gain may be smaller)? Record the measured before/after in the README; if the local-path gain is negligible, log a CL recommending the phase-2 `s3://`-direct follow-up be prioritised over shipping this default-on.

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — Streamer already bundled in `vllm/vllm-openai:v0.8.5`; no image bump for phase 1.
- CL-2 — Phase 1 = streamer over the existing local PVC path; direct `s3://` streaming deferred to a phase-2 follow-up spec.
- CL-3 — `streaming.concurrency` → `--model-loader-extra-config '{"concurrency":N}'`; other streamer tunables out of scope.
- CL-4 — LoRA resolver descoped (needs vLLM v0.9.0 + `VLLM_ALLOW_RUNTIME_LORA_UPDATING`); `streaming.enabled` stays default-false pending e2e-gated flip.
- CL-5 — `--load-format` + `--model-loader-extra-config` join the SPEC-003 CEL denylist and its lockstep canonical list.
- CL-6 — Ship in the same unreleased composition module version as SPEC-002/003 (no extra module bump).

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Similar spec: [SPEC-002 — Composition-owned AI Gateway routing](../002-composition-owned-gateway-routing/spec.md) (same InferenceService module; opt-in `enabled` block idiom); [SPEC-001 — LLM platform Prometheus autoscaling](../0001-llm-platform-prometheus-autoscaling/spec.md) (cold-start is the latency this feature reduces); SPEC-003 (`engineArgs` denylist this spec extends)
- Run:ai Model Streamer (vLLM): <https://docs.vllm.ai/en/stable/models/extensions/runai_model_streamer/> — `--load-format runai_streamer`, `--model-loader-extra-config` (`concurrency`, `memory_limit`); bundled via `vllm[runai]` in the openai image (v0.8.5 release, PR #16317)
- LoRA resolver plugins (deferred): <https://docs.vllm.ai/en/stable/features/lora/> — built-in `lora_filesystem_resolver` first shipped in vLLM v0.9.0; requires `VLLM_PLUGINS`, `VLLM_LORA_RESOLVER_CACHE_DIR`, `VLLM_ALLOW_RUNTIME_LORA_UPDATING`
