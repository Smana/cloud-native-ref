# Clarifications Log — vLLM cold-start reduction — Run:ai Model Streamer load-format for InferenceService

**Spec**: [SPEC-005](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-12 — Does phase 1 need a vLLM image bump to get the Run:ai Model Streamer?

**Asked by**: Spec author (2026-07 landscape research)
**Context**: The Run:ai Model Streamer is an optional dependency (`vllm[runai]` → `runai-model-streamer`, `runai-model-streamer-s3`, `boto3`), not part of vLLM's common requirements. If the current serving image `vllm/vllm-openai:v0.8.5` does not bundle it, even the flag-only phase-1 path would require an image bump — which affects all four fleet models, not just opt-in claims.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Streamer already bundled in v0.8.5 openai image → no bump | Flag-only change; zero blast radius on the fleet; lowest risk | Requires verifying the image build installs the `[runai]` extra |
| B | Bump the image to a streamer-native tag | Guarantees the binary | Affects all four fleet models; needs full-fleet e2e; bigger PR |
| C | Add an init/pip layer that installs `vllm[runai]` at start | No image bump | Fragile runtime pip; slows pod start (defeats the purpose); PSS read-only-FS friction |

**Decision**: A — no image bump. Verified: vLLM `setup.py` at `v0.8.5` declares `"runai": ["runai-model-streamer", "runai-model-streamer-s3", "boto3"]`, and the `docker/Dockerfile` `vllm-openai-base` stage installs `runai-model-streamer runai-model-streamer[s3]` — so the streamer binary is present in `vllm/vllm-openai:v0.8.5`. PR #16317 ("Support S3 Sharded loading with RunAI Model Streamer") shipped in the v0.8.5 release.
**Rationale**: Keeps the cold-start win a pure `--load-format` flag on the *existing* image — the lowest-risk useful increment. Image bumps are deliberately out of scope (CL-6).
**Decided by**: Controller, verified against vLLM `v0.8.5` `setup.py` extras + `docker/Dockerfile`; PR #16317 in the v0.8.5 release notes
**References**: <https://docs.vllm.ai/en/stable/models/extensions/runai_model_streamer/>; vLLM v0.8.5 release (2025-04-28); PR #16317

## CL-2 — 2026-07-12 — Phase 1 = streamer over the local PVC path, or direct `s3://` streaming?

**Asked by**: Spec author (2026-07 landscape research)
**Context**: Weights currently live on the shared `llm-models` PVC (Amazon S3 Files, EFS-CSI-mounted), populated by the composition-rendered preload Job. Run:ai Model Streamer can read either plain `s3://` URLs OR local safetensors, and speeds up local reads too via concurrent chunked reads. Direct `s3://` streaming would eliminate the preload Job but needs a plain S3 bucket (S3 Files is a *filesystem*, not a plain bucket), an EPI IAM role, and S3-egress CNP.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Phase 1 = streamer over the existing local `/models/<revision>` path (pure flag) | No new infra; keeps PVC + preload; concurrent local reads still cut load time; no AWS creds in the pod | Local-path gain may be smaller than NVIDIA's S3 benchmark (~23 s) |
| B | Phase 1 = direct `s3://`-direct streaming, drop the preload Job | Biggest theoretical win; removes the preload machinery | Needs plain S3 bucket + EPI IAM + S3-egress CNP; weights are in S3 Files not a bucket; large, higher-risk change |
| C | Ship both in one spec | End-state in one PR | Large blast radius; couples an infra migration to a flag change |

**Decision**: A — phase 1 streams over the existing local PVC path (`--load-format runai_streamer`, `--model` stays `/models/<revision>`). Direct `s3://` streaming (eliminating the preload Job) is an explicit non-goal, deferred to a phase-2 follow-up spec.
**Rationale**: Delivers the load-time win as a flag with zero new infra, no AWS creds in the vLLM pod, and no CNP/IAM churn. The `s3://`-direct path is a separate infra migration that deserves its own spec; measuring the local-path gain first (SC-005) tells us whether phase 2 is worth it.
**Decided by**: User (adopt-recos directive, 2026-07-12)
**References**: Run:ai Model Streamer docs (local + S3/GCS/Azure sources); `opentofu/llm-platform/filesystem.tf` (S3 Files filesystem, not a plain bucket); `apps/base/ai/llm/models-pvc.yaml`

## CL-3 — 2026-07-12 — How is streamer concurrency exposed on the claim?

**Asked by**: Spec author
**Context**: The streamer's threading/read tunables live under `--model-loader-extra-config`, a JSON blob accepting `concurrency`, `memory_limit`, `distributed`, `pattern`. Exposing all of them bloats the API; exposing none removes the main tuning knob.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Expose only `streaming.concurrency` → `--model-loader-extra-config '{"concurrency":N}'` | Single meaningful knob; small API; add others on demand | Users can't set `memory_limit`/`pattern` in v1 |
| B | Expose a free-form `streaming.extraConfig` map | Full flexibility | Untyped passthrough; collides with the reserved-flag philosophy; hard to validate |
| C | Expose nothing (streamer with defaults) | Smallest API | No tuning; concurrency default may under-utilise the mount |

**Decision**: A — expose `streaming.concurrency` (int, optional); when set, render `--model-loader-extra-config` with a `json.encode({concurrency = N})` value. Other keys (`memory_limit`, `distributed`, `pattern`) are out of scope, add on demand.
**Rationale**: `concurrency` is the one knob that maps directly to the local-read speed-up we're chasing; a typed single field keeps the API honest and testable (`json.decode` in `main_test.k`). The composition owns the flag, so it can't drift via `engineArgs` (CL-5).
**Decided by**: User (adopt-recos directive, 2026-07-12)
**References**: Run:ai Model Streamer `--model-loader-extra-config` keys (`concurrency`, `memory_limit`, `distributed`, `pattern`)

## CL-4 — 2026-07-12 — Is the dynamic S3/filesystem LoRA resolver in scope?

**Asked by**: Spec author (2026-07 landscape research)
**Context**: The brief proposed an opt-in `loraResolver.enabled` that switches from static `--lora-modules` to a resolver plugin fetching adapters at request time — conditional on a **built-in filesystem resolver existing at the chosen vLLM version**. Verification was required before committing.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Descope the resolver; keep this spec streamer-only; static `--lora-modules` + canary routing stay the source of truth | Matches the brief's fallback ("if no built-in resolver, descope"); no image bump; no trust-boundary change | No dynamic adapter loading in v1 |
| B | Ship the resolver in this spec | Request-time adapter fetch; fewer restarts | Requires vLLM v0.9.0+ (built-in resolver absent in current v0.8.5) → image bump; requires `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True` → runtime-LoRA API enabled → new trust boundary; must keep gateway canary `modelNameOverride` working under resolver semantics |
| C | Custom resolver plugin package | Works on any version | Build/maintain a plugin; largest surface; still needs runtime-LoRA enablement |

**Decision**: A — descope the LoRA resolver to a documented follow-up. This spec is streamer-only. Static `--lora-modules` (SPEC-002 CL-5 verbatim names) and canary routing remain the source of truth. `streaming.enabled` stays default-false; flipping to default-true is a separate e2e-gated follow-up.
**Rationale**: Verified the built-in `lora_filesystem_resolver` first ships in vLLM **v0.9.0** — `vllm/plugins/lora_resolvers/filesystem_resolver.py` is a 404 at `v0.8.5` and present at `v0.9.0`+ (the `LoRAResolver` base class exists at v0.8.5 in `vllm/lora/resolver.py`, but no shipped filesystem resolver). The resolver also requires `VLLM_PLUGINS=lora_filesystem_resolver`, `VLLM_LORA_RESOLVER_CACHE_DIR`, and `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True`. So the resolver needs an image bump (blast radius on all four models — CL-6) *and* enabling the runtime-LoRA API (a trust-boundary change) — out of proportion to a flag-only cold-start win. Keeping `VLLM_ALLOW_RUNTIME_LORA_UPDATING` unset preserves the current security posture.
**Decided by**: Controller (verification) + user (adopt-recos directive), 2026-07-12
**References**: <https://docs.vllm.ai/en/stable/features/lora/>; verified `vllm/plugins/lora_resolvers/filesystem_resolver.py` 404@v0.8.5 / 200@v0.9.0+; SPEC-002 CL-5 (verbatim adapter names)

## CL-5 — 2026-07-12 — Do the new streamer flags join the SPEC-003 engineArgs denylist?

**Asked by**: Spec author
**Context**: SPEC-003 added a `spec.engineArgs` escape hatch with a CEL denylist reserving every composition-managed vLLM flag, backed by a `main_test.k` lockstep test (XRD denylist == canonical `_reservedEngineFlags` list, and every emitted managed flag must be denied). `--load-format` and `--model-loader-extra-config` are now composition-managed.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Add both flags to the CEL denylist + the lockstep canonical list | Single source of truth for the flag; can't drift from `streaming` block; CI-enforced consistency | Two more CEL rules + two list entries |
| B | Leave them out of the denylist | Smaller diff | A user could pass `--load-format` via `engineArgs`, desyncing it from `streaming.enabled`; the lockstep test would fail (emitted managed flag not denied) |

**Decision**: A — `--load-format` and `--model-loader-extra-config` join the XRD CEL denylist (one-rule-per-flag `a != "--X" && !a.startsWith("--X=")` form, matching the existing rules) AND the `main_test.k` `_reservedEngineFlags` canonical list.
**Rationale**: The lockstep test (main_test.k:623/631) *forces* this — any managed flag emitted by the composition must appear in the denylist or CI fails. Reserving the flags keeps the `streaming` block the only way to set them, preventing drift. Mandatory integration with SPEC-003, per the brief.
**Decided by**: User (adopt-recos directive) + the existing lockstep invariant, 2026-07-12
**References**: SPEC-003 `engineArgs` denylist; `inference-service-definition.yaml` CEL rules (from line 43); `main_test.k` `test_engine_args_denylist_lockstep` (line 609)

## CL-6 — 2026-07-12 — Which composition module version ships this?

**Asked by**: Spec author
**Context**: SPEC-002 and SPEC-003 both fold into the same open PR at composition module version 0.8.0. This spec is a small args-only change on the same module.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Ship in the same unreleased 0.8.0 module (no extra bump) | One coherent release of the InferenceService module; no churn | Couples this spec's merge to the SPEC-002/003 PR timing |
| B | Cut a new module version for this spec | Independent release | Extra `kcl.mod` bump + OCI publish for an args-only change |

**Decision**: A — ship in the same unreleased 0.8.0 module as SPEC-002/003; no extra module bump. If this lands after that PR merges, bump to the next PR-prefixed tag per the `crossplane-modules.yml` flow and verify anonymous pull.
**Rationale**: This is a tiny args-only addition to a module already being revised in the same cycle; a separate version adds publish overhead for no benefit. Also keeps the image-bump non-goal clean — no image bump means no fleet-wide blast radius (CL-1, CL-4 both hinge on this).
**Decided by**: User (adopt-recos directive, 2026-07-12)
**References**: SPEC-002/003 module 0.8.0; `crossplane-modules.yml` PR-prefix publish flow; `.claude/rules/kcl-crossplane.md` #5

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/)
