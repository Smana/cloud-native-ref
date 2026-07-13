# Plan: vLLM cold-start reduction — Run:ai Model Streamer load-format for InferenceService

**Spec**: [SPEC-005](spec.md)
**Status**: draft
**Last updated**: 2026-07-12

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

New optional `streaming` block nested under the existing `spec.model` on `InferenceService` (composition module 0.8.0, same unreleased version as SPEC-002/003 — CL-6):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen-coder
  namespace: llm
spec:
  model:
    repository: Qwen/Qwen3-Coder-...
    revision: main
    contextWindow: 32768
    # NEW — all optional, default off (opt-in)
    streaming:
      enabled: true       # Optional, default: false → --load-format runai_streamer
      concurrency: 16      # Optional, int → --model-loader-extra-config '{"concurrency":16}'
  # ... existing fields unchanged (loraAdapters, gateway, scaling, engineArgs) ...
```

Root-level XRD CEL validations added (`infrastructure/base/crossplane/configuration/inference-service-definition.yaml`, alongside the existing SPEC-003 denylist rules, one-rule-per-flag `a != "--X" && !a.startsWith("--X=")` form — CL-5):

```yaml
- rule: '!has(self.engineArgs) || self.engineArgs.all(a, a != "--load-format" && !a.startsWith("--load-format="))'
  message: "--load-format is composition-managed; use spec.model.streaming.enabled"
- rule: '!has(self.engineArgs) || self.engineArgs.all(a, a != "--model-loader-extra-config" && !a.startsWith("--model-loader-extra-config="))'
  message: "--model-loader-extra-config is composition-managed; use spec.model.streaming.concurrency"
```

No CEL guard is needed for `concurrency` requiring `enabled` (concurrency without enabled simply renders no extra-config arg — the streamer flag gates it in KCL); optionally add `!has(self.model.streaming.concurrency) || self.model.streaming.enabled` for tidiness (decide during T002).

### Resources Created

No new resources. This spec adds vLLM container `args` to the *existing* serving Deployment and two CEL rules to the *existing* XRD (FR-006).

| Resource | Condition | Notes |
|----------|-----------|-------|
| (none) | — | Args-only diff on the serving Deployment; no new pod / IAM / S3 / PVC / Secret (SC-006) |

### Key Entities

- **`_streamerArgs`** (new KCL local, main.k, sits between `_baseVllmArgs`/`_loraArgs` and `_managedVllmArgs`): `["--load-format", "runai_streamer"]` when `oxr.spec.model.streaming.enabled`, plus `["--model-loader-extra-config", json.encode({concurrency = <n>})]` when `concurrency` is set; `[]` otherwise (FR-002/FR-003). Inline-conditional single expression — no post-creation mutation (function-kcl #285).
- **`_managedVllmArgs`** (existing, main.k:~137-168): `_streamerArgs` is concatenated into the managed prefix so it is ordered before user `engineArgs` and covered by the same `args == _managedVllmArgs + _engineArgs` invariant test (main_test.k:539).
- **`_reservedEngineFlags`** (existing canonical list, main_test.k:610): grows by exactly `--load-format` and `--model-loader-extra-config`; the lockstep test asserts XRD denylist == sorted canonical list (main_test.k:623) AND that every emitted managed flag is denied (main_test.k:631) — so a missing denylist entry fails CI (FR-004, SC-003).
- **`--model` path** stays `_modelLocalPath` = `/models/<revision>` (main.k:137) — the streamer reads the *local* PVC-mounted safetensors; no `s3://` URL (FR-002, CL-2).

### Dependencies

- [ ] Run:ai Model Streamer binary present in the serving image — already true: `vllm/vllm-openai:v0.8.5` bundles `runai-model-streamer` + `[s3]` (baked into the `vllm-openai-base` Docker stage; PR #16317, v0.8.5 release) — CL-1. No image bump (CL-6).
- [ ] No CNP change — the streamer reads local files over the already-mounted PVC; no new egress (contrast: phase-2 `s3://`-direct would need S3 egress CNP — non-goal).
- [ ] No `ManagedResourceActivationPolicy` / aggregate-ClusterRole change — no new managed Kinds (args-only).
- [ ] No KEDA / gateway / preload / `loraAdapters` change (FR-007) — the preload Job still populates the PVC; streamer only changes the read-into-GPU step.

### Alternatives considered

Direct `s3://` streaming (bypassing the PVC + preload Job) — rejected for phase 1 in CL-2: weights live in an S3 Files *filesystem*, not a plain bucket, so it needs a new bucket + EPI IAM + S3-egress CNP. Dynamic S3/filesystem LoRA resolver — rejected in CL-4: the built-in `lora_filesystem_resolver` first ships in vLLM v0.9.0 (verified 404 at v0.8.5, present v0.9.0+) and requires `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True`, i.e. an image bump plus a runtime-LoRA trust-boundary change — out of proportion to a flag-only cold-start win. Image bump to a streamer-native/resolver-capable version — rejected in CL-6: an image bump affects all four fleet models, not just opt-in claims, so it belongs in its own e2e-gated change.

---

## Implementation Notes

- KCL: `_streamerArgs` is a single inline-conditional list expression (no dict mutation; single-line comprehension if one is needed for the extra-config). Use `json.encode(...)` for the `--model-loader-extra-config` value so the JSON is canonical and testable with `json.decode` in `main_test.k` (CL-3).
- The two new CEL rules follow the *exact* one-rule-per-flag pattern already in the XRD (`a != "--X" && !a.startsWith("--X=")`) — do not introduce a list-membership rule; the lockstep test compares the XRD's per-flag rules against the canonical list (CL-5).
- Off-by-default must be a strict no-op: `_streamerArgs == []` when `streaming` is absent, so `_managedVllmArgs` is unchanged and SC-004's byte-identity holds. Guard against accidentally rendering `--model-loader-extra-config '{}'` when `concurrency` is unset.
- Cold-start measurement (T009): capture pod-ready → first-token by timestamping the readiness-probe pass vs. the first successful `/v1/completions` on a scaled-from-zero pod; NVIDIA's ~23 s figure is an S3 benchmark — the *local-path* gain may be smaller, so record the real before/after and, if negligible, log a CL steering effort to the phase-2 `s3://`-direct follow-up (spec Open questions).
- Rollback: set `model.streaming.enabled: false` (or drop the block) — reverts to the default loader with an args-only diff; no data migration, no re-publish beyond the claim edit.
- Module publish (CL-6): ships in the same unreleased 0.8.0 module as SPEC-002/003 — no extra `kcl.mod` bump; if this lands after that PR merges, bump to the next PR-prefixed tag per the `crossplane-modules.yml` flow and verify anonymous pull.

### File structure (composition)

```
infrastructure/base/crossplane/configuration/
├── inference-service-definition.yaml   # + spec.model.streaming schema; + 2 engineArgs CEL rules
└── kcl/inference-service/
    ├── main.k                # + _streamerArgs, folded into _managedVllmArgs
    ├── main_test.k           # + streamer on/off, concurrency→JSON, off-by-default byte-identity; grow _reservedEngineFlags
    ├── kcl.mod               # 0.8.0 (unchanged — CL-6)
    ├── settings-example.yaml # + model.streaming example
    └── README.md             # + streaming section incl. measured cold-start before/after (SC-005)
examples/
├── inferenceservice-basic.yaml     # unchanged (streaming off by default)
└── inferenceservice-complete.yaml  # + model.streaming.enabled + concurrency
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders
- `crossplane render` with both examples succeeds
- `./scripts/validate-kcl-compositions.sh` exit 0 (4-stage incl. Polaris ≥ 85, kube-linter)
- `kcl test` (main_test.k) green — denylist lockstep grows and stays consistent

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: Schema & guards

- [x] **T001**: XRD: add `spec.model.streaming` object schema (`enabled` bool default false, `concurrency` int optional, bounds 1–64) to `inference-service-definition.yaml` (FR-001). Evidence: `inferenceservice-complete.yaml` (streaming.enabled+concurrency:16) renders via `crossplane render` — validate-kcl stage 3 ✅.
- [x] **T002**: XRD: added the two `engineArgs` CEL denylist rules for `--load-format` and `--model-loader-extra-config` (one-rule-per-flag `a != "--X" && !a.startsWith("--X=")` form) after `--host` (FR-004, CL-5). Evidence: `test_engine_args_denylist_lockstep` PASS — XRD denylist == canonical list (38/38).

### Phase 2: Implementation

- [x] **T003**: KCL: added `_streamerArgs` local — `--load-format runai_streamer` when enabled, `--model-loader-extra-config json.encode({concurrency})` when concurrency set, `[]` otherwise — folded into `_managedVllmArgs` before `engineArgs` (FR-002, FR-003, FR-005). Single inline-conditional; `!= Undefined` guard so `concurrency` unset ⇒ no `'{}'` extra-config. Evidence: `kcl run` render shows `['--load-format','runai_streamer','--model-loader-extra-config','{"concurrency": 16}']` in the managed prefix, before user engineArgs.
- [x] **T004**: KCL/README: `--model` stays `_modelLocalPath` (no `s3://`) — asserted by `test_streaming_model_stays_local`; README "Model Streamer (cold-start)" section documents the local-PVC read + no new pod/IAM/S3 (FR-006, FR-007, CL-1, CL-2).
- [x] **T005**: `main_test.k`: added `test_streaming_off_by_default` (flags absent + `_streamerArgs == []`), `test_streaming_enabled_flag` (present when enabled; `[]` when concurrency-without-enabled), `test_streaming_concurrency_extra_config` (`json.decode` → `concurrency==16`), `test_streaming_model_stays_local`; grew `_reservedEngineFlags` +2 (FR-004/FR-005). Evidence: `kcl test` PASS 38/38 (was 34), incl. `test_engine_args_denylist_lockstep`.

### Phase 3: e2e (feature-branch cluster)

- [ ] **T006**: SC-001/SC-002 — apply a claim with `streaming: {enabled: true, concurrency: 16}`; `kubectl get deploy -o json | jq` the vLLM args for `--load-format runai_streamer` and the extra-config JSON
- [ ] **T007**: SC-003 — apply a claim passing `--load-format` (and `--model-loader-extra-config`) via `engineArgs`; capture the CEL admission rejection naming each flag
- [ ] **T008**: SC-006 — enable streaming on a live claim; `kubectl diff` / rendered `git diff` shows an args-only Deployment change (KEDA / gateway / preload / PVC / Secrets untouched); `hubble observe --pod llm/<pod> --verdict DROPPED` clean
- [ ] **T009**: SC-005 — one fleet model, measure pod-ready → first-token (scaled-from-zero) streaming off vs on; record both numbers in the README; resolve the spec Open-questions observation

### Phase 4: Validation & Documentation

- [~] **T010**: `kcl test` green (38/38, SC-007). `./scripts/validate-kcl-compositions.sh` stages 2 (syntax) + 3 (render — both examples) pass; stage 1 (git-clean) fails on the uncommitted tree as expected (files are edited-not-reformatted; `kcl fmt` is idempotent). Polaris ≥ 85 / kube-linter is the security stage — deferred to the module-publish + `/crossplane-validator` run on the PR (module renders via published OCI, not the local tree — CL-6/T007 flow).
- [x] **T011**: README.md "Model Streamer (cold-start)" section added (measured before/after table stubbed for T009 e2e); `settings-example.yaml` kept streaming-off to preserve the off-by-default byte-identity fixture (enabled path synthesized in `main_test.k` per the suite's fixture-driven style); `examples/inferenceservice-complete.yaml` gains `model.streaming.enabled + concurrency:16`. Evidence: both examples render via `crossplane render` (validate-kcl stage 3 ✅).

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-12> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (cold-start load phase undermines KEDA scale-from-zero; read-into-GPU step untouched today)
- [x] User stories capture real user needs (US-1 opt-in faster load, US-2 flags stay composition-owned, US-3 measured win)
- [x] Acceptance scenarios are testable (each maps to an SC with a concrete `jq`/`crossplane render`/CEL check)
- [x] Scope is well-defined (Non-Goals: `s3://`-direct streaming, LoRA resolver, image bump, default-on flip, extra tunables)
- [x] Success criteria are measurable (SC-001…007, falsifiable per validator/cluster)

### Platform Engineer

- [x] Design follows existing patterns (opt-in nested block on the InferenceService module; mirrors SPEC-002 `gateway.enabled` / SPEC-003 `engineArgs` idioms)
- [x] API is consistent with other compositions (`streaming.enabled` bool default false; nested under existing `spec.model`)
- [x] Resource naming follows `xplane-*` convention (no new resources; claims already `xplane-*` — N/A for rendered args)
- [x] KCL avoids mutation pattern (`_streamerArgs` is a single inline-conditional expression — Implementation Notes)
- [x] Examples provided (basic stays streaming-off; complete gains `model.streaming` — T011)

### Security & Compliance

- [x] Zero-trust networking (no new pods/egress; streamer reads the already-mounted PVC — no CNP change; phase-2 `s3://` egress is a non-goal)
- [x] Least-privilege RBAC (no new managed Kinds; no aggregate-ClusterRole change)
- [x] Secrets via External Secrets (no new secrets; no AWS creds needed for local-path streaming — CL-2)
- [x] Security context enforced (no new pods; serving pod context unchanged; runtime-LoRA API stays DISABLED — `VLLM_ALLOW_RUNTIME_LORA_UPDATING` not set, resolver descoped in CL-4)
- [x] IAM policies scoped to `xplane-*` resources (N/A — no AWS resources touched in phase 1)

### SRE

- [x] Health checks defined (no new pods; existing liveness/readiness/startup probes unchanged — streamer only changes load speed, and the startup probe already covers slow loads)
- [x] Observability configured (VMServiceScrape unchanged; cold-start before/after recorded via readiness→first-token timing — SC-005/T009)
- [x] Resource requests + limits appropriate (no new pods; streamer respects `--model-loader-extra-config.memory_limit` — not exposed in v1, default CPU-buffer behavior)
- [x] Failure modes documented (CEL admission rejection for reserved flags; off-by-default no-op guarded against accidental empty extra-config; rollback = disable flag)
- [x] Recovery / rollback path clear (set `streaming.enabled: false` / drop the block — args-only revert, no data migration — Implementation Notes)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/inference-service/` (this module, 0.8.0) — `_managedVllmArgs`/`_engineArgs` at main.k:137-168; `_reservedEngineFlags` lockstep at main_test.k:610
- XRD: `infrastructure/base/crossplane/configuration/inference-service-definition.yaml` (engineArgs CEL denylist, one-rule-per-flag from line 43)
- Related: SPEC-002 (composition-owned gateway routing — same module), SPEC-003 (`engineArgs` escape hatch + denylist this spec extends), SPEC-001 (KEDA leading-signal autoscaling — the latency this feature reduces)
- Vendor: Run:ai Model Streamer <https://docs.vllm.ai/en/stable/models/extensions/runai_model_streamer/>; LoRA resolver (deferred) <https://docs.vllm.ai/en/stable/features/lora/>
