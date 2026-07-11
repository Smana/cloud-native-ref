# Plan: InferenceService v0.8.0: spec.engineArgs escape hatch with reserved-flag CEL denylist and structured status.servedModels

**Spec**: [SPEC-003](spec.md)
**Status**: draft
**Last updated**: 2026-07-11

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

New optional `spec.engineArgs` field on `InferenceService` (composition v0.7.0 → v0.8.0):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen-coder
  namespace: llm
spec:
  model:
    repository: Qwen/Qwen3-8B
    maxNumSeqs: 128          # curated — feeds KEDA (reserved: --max-num-seqs)
  gpu:
    count: 1

  # Optional escape hatch (default: absent). Each entry is ONE verbatim
  # single-token vLLM CLI arg, `--flag` or `--flag=value`. Appended AFTER
  # all composition-managed flags. Reserved flags rejected at admission.
  engineArgs:                # Optional array (maxItems: 16 — CL-4)
    - --enforce-eager
    - --kv-cache-dtype=fp8
    - --rope-scaling={"rope_type":"yarn","factor":2.0}   # `=value` may contain anything but a leading space
```

Root-level (spec-scoped) XRD CEL validations (all reject at admission — CL-1):

- **`--` prefix (FR-004 — CL-4)**:
  `!has(self.engineArgs) || self.engineArgs.all(a, a.startsWith("--"))`
  message: `"each spec.engineArgs entry must be a single token starting with '--' (use --flag=value, not --flag value)"`
- **Reserved-flag denylist (FR-003 — CL-1)** — one CEL rule per reserved flag so each message can name its curated field. The flag token is `a.split("=")[0]` (the substring before the first `=`, or the whole entry when no `=`). Pattern per reserved flag `F` with pointer `P`:
  `!has(self.engineArgs) || self.engineArgs.all(a, a.split("=")[0] != "F")`
  message: `"F is composition-managed; use P"`.

  | Reserved flag (token) | CEL pointer message fragment |
  |---|---|
  | `--model` | `use spec.model.repository (composition sets the local weights path)` |
  | `--served-model-name` | `the served model name is the claim name (metadata.name)` |
  | `--max-model-len` | `use spec.model.contextWindow` |
  | `--max-num-seqs` | `use spec.model.maxNumSeqs (it is the KEDA scaling denominator)` |
  | `--gpu-memory-utilization` | `composition-managed (fixed at 0.92)` |
  | `--quantization` | `use spec.model.quantization` |
  | `--enable-prefix-caching` | `use spec.cache.prefixCache.enabled` |
  | `--cpu-offload-gb` | `use spec.cache.kvOffload.{enabled,sizeGB}` |
  | `--enable-auto-tool-choice` | `use spec.model.toolCallParser` |
  | `--tool-call-parser` | `use spec.model.toolCallParser` |
  | `--enable-lora` | `use spec.loraAdapters` |
  | `--max-loras` | `use spec.loraAdapters` |
  | `--max-lora-rank` | `use spec.loraAdapters (rank fixed at 64)` |
  | `--lora-modules` | `use spec.loraAdapters` |
  | `--port` | `serving-contract flag; the vLLM port is fixed at 8000 (Service/probes/Backend depend on it)` |
  | `--host` | `serving-contract flag; managed by the composition` |

  **CEL cost note (CL-4)**: this is `maxItems(16) × 16 reserved-flag rules`, each a bounded `.all()` with a `split` + string compare — well under the per-resource CEL cost budget. `maxItems: 16` on `engineArgs` bounds it deterministically.

`status.servedModels` (FR-005): computed in KCL purely from `spec` (no `ocds` read). One `base` entry (claim name), one `adapter` entry per `loraAdapters[]` (name verbatim), `canaryWeightPercent` only where a `gateway.canaries[]` entry targets that adapter.

### Resources Created

No **new** managed resources. The feature is entirely: (a) two XRD schema additions + CEL, (b) two KCL edits (args tail-append, status write), (c) an `additionalPrinterColumns` entry.

| Change | Condition | Notes |
|--------|-----------|-------|
| vLLM container `args` gains a trailing slice | `spec.engineArgs` non-empty | `_vllmArgs + _engineArgs`; last in the list |
| `status.servedModels` populated on the XR (dxr) | Always | Merged into the same `_dxrStatus` patch SPEC-002 introduced for `status.modelEndpoint` |
| `additionalPrinterColumns` (served models) | Always (XRD-level) | JSONPath over `status.servedModels[*].name` |

### Key Entities

- **`_engineArgs`**: `oxr.spec.engineArgs or []`. Appended once at the end of `_vllmArgs` assembly (currently `main.k:159`). Verbatim — no transform.
- **Reserved-flag set**: lives in the XRD as CEL only (NOT duplicated in KCL). Admission is the single enforcement point (CL-1); the composition trusts that anything reaching it is already collision-free, so KCL stays a plain append with no re-validation.
- **`_servedModels`**: single-line list comprehensions — `[{name = _name, kind = "base"}]` plus `[{name = a.name, kind = "adapter", **({canaryWeightPercent = w} if <a targeted by a canary> else {})} for a in _loraAdapters]`. Built with inline conditional dict construction (no post-creation mutation — function-kcl #285). A small canary-weight lookup (`{c.adapter: c.weightPercent for c in _gatewayCanaries}`) resolves the optional field per adapter.
- **`_servedModelsSummary`**: comma-joined `[m.name for m in _servedModels]`, set on the dxr status alongside `servedModels` (the scalar printer-column source — CL-5; T004 will implement it).
- **dxr status patch**: SPEC-002 already spreads `**option("params").dxr` and sets `status.modelEndpoint` inside the `_gatewayEnabled` block. `status.servedModels` MUST be set **unconditionally** (adapters/base exist regardless of gateway), so the status-patch construction moves out of the `if _gatewayEnabled` block into an always-run `_dxrStatus` that conditionally includes `modelEndpoint`.

### Dependencies

- [ ] SPEC-002 (PR #1559) merged — provides `gateway.canaries[]` and the dxr status-patch pattern this builds on (CL-3).
- [ ] No new provider, CRD, `ManagedResourceActivationPolicy`, or aggregate ClusterRole change (no new managed Kinds — Crossplane v2 trap #2/#3 N/A).
- [ ] No CiliumNetworkPolicy change (no new pods/network paths).
- [ ] No IAM change (no AWS resources touched).

### Alternatives considered

`engineArgs` as a raw `map[string]string` (flag→value) — rejected: forces the composition to re-serialise `--flag=value` and can't express valueless flags cleanly; a `[]string` of verbatim tokens is simpler and order-preserving. Composition-wins-silently and reject-at-render enforcement — both rejected in CL-1. Plain-string `status.servedModels` — rejected in CL-2.

---

## Implementation Notes

- KCL: inline-conditional dict construction only (function-kcl #285 — no post-creation mutation); single-line list comprehensions; rename loop vars in dict comprehensions (shadowing trap). The canary-weight lookup dict comprehension must use a non-shadowing loop var (`for c in _gatewayCanaries`).
- Enforcement lives in ONE place — the XRD CEL (CL-1). Do NOT re-implement the reserved denylist in KCL; that would be two sources of truth for the same rule. The composition appends verbatim and trusts admission.
- The reserved list is derived from `main.k`'s actual emitted flags (`_baseVllmArgs`, `_quantArgs`, `_prefixCacheArgs`, `_kvOffloadArgs`, `_toolCallArgs`, `_loraArgs` at `main.k:136-159`), plus `--port`/`--host` which the code does NOT emit but whose defaults (8000/all-interfaces) are load-bearing for the Service, health probes, and gateway `Backend` FQDN port. Reserving them prevents a user silently breaking the serving contract. This distinction is documented in the composition README.
- `status.servedModels` is computed from spec only (no `ocds`) so it is populated on the first reconcile, independent of Deployment/route readiness. It is a *topology* projection, not a health signal (see Non-Goals).
- Composition OCI publish flow (same CI PR-tag dance as SPEC-002): bump `kcl.mod` version to `0.8.0`; the `crossplane-modules.yml` workflow rewrites `kcl.mod` to the PR-prefixed tag (`0.8.0-pr<N>`) before `kcl mod push` (the push uses the `version` field, not the URL tag suffix — KCL rule #5); verify the tag is anonymously pullable before pointing the composition `Function` pin at it; re-render.
- Feature-branch cluster: deploy with `TF_VAR_flux_git_ref='refs/heads/<branch>'`; after merge restore the FluxInstance to main before the head branch auto-deletes.
- Rollback path: remove `spec.engineArgs` from the claim (pure spec revert, no composition re-publish) reverts arg behaviour; reverting the composition pin to `0.7.0` fully reverts the feature — no managed resource is created or deleted, so rollback carries no data risk.

### File structure (composition)

```
infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k                 # + _engineArgs tail-append; + _servedModels; dxr status moved out of gateway block
├── main_test.k            # + engineArgs/ordering/servedModels cases
├── kcl.mod                # 0.8.0
├── settings-example.yaml  # + engineArgs example
└── README.md              # + engineArgs + reserved-flag table + servedModels docs
infrastructure/base/crossplane/configuration/inference-service-definition.yaml
                           # + spec.engineArgs schema + CEL; + status.servedModels schema; + printer column
examples/
├── inferenceservice-basic.yaml      # unchanged (engineArgs absent)
└── inferenceservice-complete.yaml   # + engineArgs example entry
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders
- `crossplane render` with both examples succeeds
- `./scripts/validate-kcl-compositions.sh` exit 0 (4-stage incl. Polaris ≥ 85, kube-linter)
- CEL rejection verified live: `kubectl apply` a reserved-flag claim → API-server error names the curated field (SC-002/SC-003)

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: XRD schema + CEL

- [ ] **T001**: XRD: add `spec.engineArgs` (`array` of `string`, `maxItems: 16`) with description; add the `--` prefix CEL rule (FR-004) and one reserved-flag CEL rule per flag in the Design table (FR-003), each message naming the curated field (CL-1, CL-4)
- [ ] **T002**: XRD: add `status.servedModels` object-list schema `{name, kind (enum base|adapter), canaryWeightPercent (optional int)}` (FR-005); add the served-models `additionalPrinterColumns` entry (FR-006); leave `status.phase`/`status.modelEndpoint` untouched (FR-007)

### Phase 2: Composition (KCL)

- [ ] **T003**: `main.k`: add `_engineArgs = oxr.spec.engineArgs or []`; append it as the last slice of `_vllmArgs` (FR-002) so managed flags always precede user flags
- [ ] **T004**: `main.k`: build `_servedModels` (base + one per `loraAdapters[]`, `canaryWeightPercent` only for canary-targeted adapters — FR-005) via single-line comprehensions + inline-conditional dicts (no mutation, #285); move the dxr status patch out of the `if _gatewayEnabled` block so `servedModels` is always set and `modelEndpoint` is included only when `gateway.enabled` (FR-007)

### Phase 3: Tests

- [ ] **T005**: `main_test.k`: engineArgs appended verbatim and LAST; explicit managed-flags-still-win ordering assertion; empty/absent engineArgs ⇒ args byte-identical to baseline (FR-001/FR-002; SC-001/SC-006)
- [ ] **T006**: `main_test.k`: `servedModels` shapes — base-only; base+adapters (no canaryWeightPercent key present); base+adapter+canary (`canaryWeightPercent` set, matches the canary weight); names match the rendered `AIGatewayRoute` match/override values (FR-005; SC-004); confirm the existing 31 tests still pass (SC-006)

### Phase 4: Publish, examples, docs

- [ ] **T007**: Bump `kcl.mod` → `0.8.0`; publish module via `crossplane-modules.yml` PR-tag flow; verify `0.8.0-pr<N>` anonymously pullable; point the composition `Function` pin at the new tag; re-render (Implementation Notes)
- [ ] **T008**: `settings-example.yaml` + `examples/inferenceservice-complete.yaml`: add an `engineArgs` example (basic stays unset); README.md: document `engineArgs`, the reserved-flag table with curated-field pointers (incl. the `--port`/`--host` serving-contract note), and `status.servedModels`
- [ ] **T009**: `./scripts/validate-kcl-compositions.sh` exit 0 (incl. Polaris ≥ 85, kube-linter); both examples render via `crossplane render`

### Phase 5: Live verification (feature-branch cluster)

- [ ] **T010**: SC-002/SC-003 — apply reserved-flag and non-`--` claims, capture the CEL admission rejections naming the curated field / prefix rule
- [ ] **T011**: SC-004/SC-005 — on `xplane-qwen-coder`, verify `status.servedModels` (base + adapters + canary weight) matches the rendered `AIGatewayRoute`, and the printer column populates

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-11> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

- <2026-07-11> T002/FR-006 adjusted: the printer column reads a new scalar status.servedModelsSummary (comma-joined names, computed by the composition) because server-side additionalPrinterColumns render only the first wildcard JSONPath match; structured status.servedModels is unchanged (CL-5).

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (release round-trip for every new vLLM flag; load-bearing flags feed KEDA/gateway; no machine-readable served-model topology)
- [x] User stories capture real user needs (US-1 add a flag without a release, US-2 fail fast on managed flags, US-3 reject two-token form, US-4 discover served models)
- [x] Acceptance scenarios are testable (each maps to an SC with a render assertion, CEL rejection, or `kubectl`/`jq` check)
- [x] Scope is well-defined (Non-Goals: no vLLM-flag validity check, no dedup/reorder, no multi-token, no health in servedModels, no curated-field changes)
- [x] Success criteria are measurable (SC-001…006, falsifiable per validator/render/cluster)

### Platform Engineer

- [x] Design follows existing patterns (extends the InferenceService module in place; reuses SPEC-002's dxr status-patch idiom; CEL-at-admission mirrors SPEC-002's canary validations)
- [x] API is consistent with other compositions (optional array field, mirrors `loraAdapters[]`/`externalSecrets[]`/`engineArgs`-style token lists; `maxItems` bound like `canaries[]`)
- [x] Resource naming follows `xplane-*` convention (no new resources rendered; served-model names inherit the claim name / verbatim adapter names)
- [x] KCL avoids mutation pattern (Design + Implementation Notes mandate inline-conditional dict construction and single-line comprehensions; non-shadowing loop vars)
- [x] Examples provided (basic stays engineArgs-off; complete gains an `engineArgs` entry — T008)

### Security & Compliance

- [x] Zero-trust networking (N/A — no new pods or network paths; existing serving CiliumNetworkPolicy unchanged)
- [x] Least-privilege RBAC (N/A — no new managed Kinds, no aggregate ClusterRole change)
- [x] Secrets via External Secrets (N/A — no new secrets; engineArgs are non-secret CLI flags, rendered into a Deployment spec like existing args)
- [x] Security context enforced (N/A — serving pod securityContext unchanged; engineArgs cannot alter it, they are appended container args only)
- [x] IAM policies scoped to `xplane-*` resources (N/A — no AWS resources touched)

### SRE

- [x] Health checks defined (N/A — no new pods; liveness/readiness/startup probes on the serving pod unchanged)
- [x] Observability configured (N/A — VMServiceScrape/VMRule unchanged; `status.servedModels` adds topology visibility on the XR + printer column)
- [x] Resource requests + limits appropriate (N/A — no new pods; serving resources unchanged)
- [x] Failure modes documented (bad/unknown engineArgs ⇒ vLLM fails at container start, CrashLoopBackOff observable in logs — documented Non-Goal; reserved-flag/`--`-prefix collisions rejected at admission)
- [x] Recovery / rollback path clear (remove `spec.engineArgs` for behaviour revert; revert composition pin to 0.7.0 for full revert — no managed resource created/deleted, no data risk — Implementation Notes)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition/spec: SPEC-002 (`../002-composition-owned-gateway-routing/`) — `gateway.canaries[]`, dxr status patch, CEL-at-admission
- This module (v0.7.0): `infrastructure/base/crossplane/configuration/kcl/inference-service/` (`main.k:136-159` managed flags, `main.k:499-511` dxr status)
- vLLM engine args: <https://docs.vllm.ai/en/stable/configuration/engine_args.html>
