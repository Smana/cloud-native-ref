# Plan: Per-InferenceService InferencePool + Endpoint Picker (GAIE v1.5.0) smart routing behind Envoy AI Gateway

**Spec**: [SPEC-004](spec.md)
**Status**: draft
**Last updated**: 2026-07-12

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable.

---

## Design

### API / Interface

New optional `endpointPicker` sub-block inside the existing SPEC-002 `gateway` block on `InferenceService` (composition v0.8.0, unreleased — same PR as SPEC-002/003):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen-coder
  namespace: llm
spec:
  # ... existing fields unchanged ...
  gateway:
    enabled: true              # SPEC-002 — required for endpointPicker (CEL)
    endpointPicker:
      enabled: true            # Optional, default: false (opt-in). Renders GAIE
                               # InferencePool + EPP and re-points the base rule.
    # canaries: []             # MUTUALLY EXCLUSIVE with endpointPicker (CEL, CL-4)
```

Root-level XRD CEL validations (reject at admission):
- `!has(self.gateway.endpointPicker) || self.gateway.enabled` (FR-002, CL-1)
- `!(has(self.gateway.endpointPicker) && self.gateway.endpointPicker.enabled && has(self.gateway.canaries) && self.gateway.canaries.size() > 0)` — endpointPicker ⊻ canaries (FR-005, CL-4)

`status.modelEndpoint` unchanged (SPEC-002 sets it when `gateway.enabled`).

### Resources Created (when `gateway.endpointPicker.enabled`, on top of SPEC-002)

| Resource | Condition | Notes |
|----------|-----------|-------|
| `HelmRelease` `<name>-epp` (helm.toolkit.fluxcd.io/v2) | `endpointPicker.enabled` | chart `inferencepool` v1.5.0 via `chartRef` → shared `llm`/`inferencepool` OCIRepository (same-namespace, CL-2); static-ready |
| `InferencePool` `<name>` (inference.networking.k8s.io/v1) | Created **by the chart** | `modelServers.matchLabels: {app.kubernetes.io/name: <name>}` (CL-5), `targetPorts:[{number:8000}]`, `modelServerType: vllm` |
| EPP `Deployment` + `Service` `<name>-epp` | Created **by the chart** | ext-proc on `9002`; image `registry.k8s.io/gateway-api-inference-extension/epp:v1.5.0`; PSS enforcement per CL-7 |
| `CiliumNetworkPolicy` `<name>-epp` (cilium.io/v2) | `endpointPicker.enabled` | default-deny + explicit allow (FR-007, CL-6); static-ready |
| `VMServiceScrape` `<name>-epp` | `endpointPicker.enabled` | selects the EPP Service (FR-010, CL-8) |
| **Modified**: `AIGatewayRoute` `<name>` base rule | `endpointPicker.enabled` | `backendRefs → [{group: inference.networking.k8s.io, kind: InferencePool, name: <name>}]` instead of the AIServiceBackend chain (FR-004, CL-3) |
| **Suppressed**: `Backend`/`AIServiceBackend` for the base rule | `endpointPicker.enabled` | Base-rule backend chain no longer referenced; pin-rule `AIServiceBackend` for `loraAdapters[]` stays if adapters exist (they still route via the claim Service) |

`AIGatewayRoute` rule construction with endpointPicker on:
1. Base rule — match `x-ai-eg-model: <name>` → `[{group: inference.networking.k8s.io, kind: InferencePool, name: <name>}]` (no `weight`, no `modelNameOverride` — unsupported on InferencePool backendRefs, CL-4).
2. Per `loraAdapters[]` — pin rule `x-ai-eg-model: <loraAdapters[].name>` → `[{name: <name>, weight: 100}]` via the AIServiceBackend chain, unchanged from SPEC-002 (FR-004). Adapters are explicit-name routes and stay on the Service path.

### Key Entities

- **EPP (Endpoint Picker)**: GAIE ext-proc server; scrapes vLLM `/metrics`, scores queue-depth + KV-cache + prefix affinity + LoRA, returns the chosen endpoint to Envoy per request. Rendered by the chart, one per claim, scoped to the claim's pods (CL-5).
- **InferencePool CR**: selects the claim's vLLM pods via `modelServers.matchLabels`; the chart owns its lifecycle (not composition-rendered directly, so no CRD-namespacing trap for a directly-managed MR).
- **Readiness latch (reused, SPEC-002)**: `_route_live = _gatewayRouteSuffix in ocds`; render `AIGatewayRoute` iff Deployment `Available=True` OR route already in `ocds`. The InferencePool backendRef swap is orthogonal to the latch — the route body changes, the gate does not (FR-006).
- **Naming**: HelmRelease/CNP/VMServiceScrape `<name>-epp`; InferencePool `<name>` (chart `inferencePool.name`); all inherit the `xplane-*` claim name.

### Dependencies

- [x] GAIE `inferencepool` chart v1.5.0 sourced: `flux/sources/ocirepo-inferencepool.yaml` (`OCIRepository`, `llm` ns) — verified, instantiated nowhere today.
- [x] InferencePool CRDs installed: `crds/base/kustomization-inference-extension.yaml` (`inference.networking.k8s.io`) — verified.
- [x] Envoy AI Gateway v1.0.0 supports InferencePool backendRefs (`group: inference.networking.k8s.io`) — verified via the AIGatewayRoute+InferencePool guide.
- [x] helm-controller allows cross-namespace `chartRef` (no `--no-cross-namespace-refs` flag set) — verified; CL-2 keeps it same-namespace anyway so this is moot.
- [x] Aggregate ClusterRole grant added to `infrastructure/base/crossplane/providers/additional-rbac.yaml`: `helm.toolkit.fluxcd.io/helmreleases` on `inference-service:aggregate-to-crossplane` (the composition now renders a HelmRelease itself). Per CL-2 the chart owns the `InferencePool` CR, so `inferencepools` is NOT granted; `ocirepositories` NOT needed (shared source). The EPP CNP + VMServiceScrape reuse the `cilium.io` / `operator.victoriametrics.com` grants already on `app-composition:aggregate-to-crossplane` (same crossplane SA). Crossplane v2 trap #3.
- [ ] PSS=restricted for the EPP pod — chart exposes no `securityContext` value key; enforcement path per CL-7 (Option A trust-and-verify, Kyverno-mutate fallback pre-authored). Confirmed on-cluster in T010 (e2e).

### Alternatives considered

Rendering the InferencePool + EPP Deployment/Service directly as native manifests (no HelmRelease) — rejected: duplicates the chart's EPP wiring and RBAC helpers, drifts from upstream v1.5.0 on every bump. Per-claim OCIRepository — rejected: two claims would collide on a shared name and a per-claim source is pointless churn; the static `llm`-namespace source is reused (CL-2). Cross-model shared InferencePool — rejected (CL-5): breaks per-model scoping and LoRA-awareness. Weighted canary through InferencePool — impossible upstream (CL-4), so canaries stay on the AIServiceBackend path and the two are CEL-mutually-exclusive.

---

## Implementation Notes

- KCL: inline-conditional dict construction only (function-kcl #285 — no post-creation mutation); single-line list comprehensions; rename loop vars in dict comprehensions (shadowing trap). The base-rule `backendRefs` is chosen by an inline conditional on `_endpointPickerEnabled`, not by mutating the SPEC-002 rule dict.
- HelmRelease values are inline in the rendered `spec.values` (verified chart keys — CL-2): `inferencePool.modelServers.matchLabels`, `inferencePool.targetPorts`, `inferencePool.modelServerType: vllm`, `inferencePool.apiVersion: inference.networking.k8s.io/v1`, `provider.name: none`, `inferenceExtension.replicas: 1`, `inferenceExtension.image` pinned to v1.5.0. No hardcoded credentials (constitution 3.2 — N/A, EPP needs none).
- CNP for EPP (CL-6, cilium-network-policies.md traps): DNS egress MUST carry `rules.dns.matchPattern: "*"` (trap #1); kube-apiserver egress uses `toEntities: ["kube-apiserver"]` (EPP watches Pods + InferencePool — verify the EPP RBAC/watch surface on-cluster); vLLM `:8000` scrape egress via `toEndpoints` on the claim's pod labels; ext-proc ingress on `9002` from the Envoy data-plane pods (`envoy-gateway-system`, `gateway.envoyproxy.io/owning-gateway-*` labels — reuse the SPEC-002 selector). Extend the claim's **serving** CNP `_metricsIngress`/`_defaultIngress` to allow EPP `:8000` ingress (FR-007).
- PSS=restricted (CL-7): the `inferencepool` chart has no `securityContext` value; first verify whether the upstream EPP image already runs compliant (likely — GAIE targets restricted). If not, the fallback is a namespace-scoped Kyverno mutate policy (the platform already runs Kyverno) — decided in CL-7, confirmed in the e2e admission task, not guessed here.
- Route latch interplay (FR-006): `main_test.k` must assert the `AIGatewayRoute` is still withheld when the Deployment is unready **in the endpointPicker path**, and that once latched the base rule carries the InferencePool backendRef.
- Composition OCI publish flow: NO version bump — this rides the unreleased `0.8.0-pr1559` tag republished by `crossplane-modules.yml` on push (shared with SPEC-002/003). Verify anonymous pull of the republished tag before pointing the composition at it.
- Feature-branch cluster: `TF_VAR_flux_git_ref='refs/heads/feat/composition-owned-gateway-routing' terramate ... deploy`.
- Rollback: set `endpointPicker.enabled: false` — the base rule reverts to the SPEC-002 AIServiceBackend chain and the HelmRelease/EPP/CNP/VMServiceScrape are GC'd. Single-field revert; no composition re-publish, no `route.yaml` change (unmigrated models untouched).

### File structure (composition)

```
infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k                 # + _endpointPickerEnabled, HelmRelease, EPP CNP, EPP VMServiceScrape, base-rule backendRef switch
├── main_test.k            # + endpointPicker on/off, canary-exclusion, latch-in-EPP-path cases
├── kcl.mod                # 0.8.0 (unchanged — shared PR tag)
├── settings-example.yaml  # + gateway.endpointPicker example
└── README.md              # + endpointPicker section (when to enable, N=1 vs N>1, canary exclusivity, EPP metrics)
examples/
├── inferenceservice-basic.yaml      # unchanged (endpointPicker off)
└── inferenceservice-complete.yaml   # note: complete already has canaries → keep endpointPicker on a separate example or gate it (canaries + endpointPicker are exclusive)
infrastructure/base/crossplane/providers/additional-rbac.yaml  # + inferencepools grant
```

### Validation path

- `kcl fmt` passes
- `kcl run -Y settings-example.yaml` renders
- `crossplane render` with the endpointPicker example succeeds; rendered `HelmRelease` + `CiliumNetworkPolicy` + `VMServiceScrape` + InferencePool-backed `AIGatewayRoute` present
- `kubeconform` on the rendered HelmRelease + AIGatewayRoute
- `./scripts/validate-kcl-compositions.sh` exit 0 (4-stage incl. Polaris ≥ 85, kube-linter)

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1: Prerequisites

- [x] **T001**: Aggregate ClusterRole delta added to `additional-rbac.yaml` — `helm.toolkit.fluxcd.io/helmreleases` granted on `inference-service:aggregate-to-crossplane` (the composition now renders a HelmRelease directly). Per CL-2 the chart — not the composition — owns the `InferencePool` CR, so `inferencepools` is deliberately NOT granted; the EPP CNP + VMServiceScrape reuse the `cilium.io` / `operator.victoriametrics.com` grants already on `app-composition:aggregate-to-crossplane` (same crossplane SA). The `kubectl auth can-i` checks are on-cluster (deferred to e2e); `yq` parse of the role is clean.
- [x] **T002**: XRD `gateway.endpointPicker.{enabled}` schema added (default false) + the two root-level CEL validations (endpointPicker⇒gateway.enabled; endpointPicker ⊻ canaries[], both with actionable messages) (FR-002, FR-005). `yq` confirms 27 CEL rules and the new `endpointPicker` property.

### Phase 2: Implementation

- [x] **T003**: KCL renders the per-claim `HelmRelease` `<name>-epp` (chart `inferencepool` via same-namespace `chartRef` → `llm`/`inferencepool` OCIRepository, `releaseName = <name>`) under `_endpointPickerEnabled`, with the verified v1.5.0 values transcribed exactly (`inferencePool.modelServers.matchLabels {app.kubernetes.io/name: <name>}`, `targetPorts [{number:8000}]`, `modelServerType vllm`, `apiVersion inference.networking.k8s.io/v1`, `provider.name none`, `inferenceExtension.replicas 1` + image pinned v1.5.0) (FR-001, FR-003, CL-2, CL-5). Verified via `kcl run` of the endpointpicker example → `HelmRelease/xplane-qwen-coder-epp` with all keys present.
- [x] **T004**: KCL switches the `AIGatewayRoute` base-rule `backendRefs` to the InferencePool ref (`{group: inference.networking.k8s.io, kind: InferencePool, name: <name>}`, no weight/modelNameOverride) via the pure `_baseRuleBackendRefsFor` inline-conditional lambda; `loraAdapters[]` pin rules and the readiness latch unchanged (FR-004, FR-006, CL-3). `kcl run` shows the base rule carrying the InferencePool ref with the pin rules intact.
- [x] **T005**: KCL renders the EPP `CiliumNetworkPolicy` `<name>-epp` (egress vLLM:8000 via `toEndpoints`, kube-apiserver via `toEntities`, kube-dns:53 UDP/TCP with `rules.dns.matchPattern "*"`; ingress ext-proc:9002 from the Envoy data plane owning-gateway selector) and extends the serving CNP with an EPP `:8000` ingress peer, gated on `_endpointPickerEnabled` (FR-007, CL-6). Rendered CNP verified against the cilium-network-policies.md traps.
- [x] **T006**: KCL renders the EPP `VMServiceScrape` `<name>-epp` selecting the EPP Service (chart label `app.kubernetes.io/name: <name>-epp`) on the `http-metrics` port (FR-010, CL-8).
- [x] **T007**: PSS=restricted for the EPP pod per CL-7 — primary path (Option A) is to trust the upstream EPP image's baked-in restricted context (the chart exposes NO securityContext value key, so no composition-side plumbing is possible) and verify admission on-cluster in T010; the Kyverno-mutate fallback (Option B) is pre-authored in the decision but only landed if e2e admission fails. No main.k change; documented in the README EPP-security section. The `[NEEDS CLARIFICATION]` / Open question stays open pending T010 (FR-008, CL-7).
- [x] **T008**: `main_test.k` SPEC-004 block (6 new tests, 44/44 pass): endpointPicker OFF-by-default through `items` → zero HelmRelease/EPP CNP/EPP VMServiceScrape + serving CNP carries no EPP peer + base rule keeps the SPEC-002 shape (count assertion); base-rule backendRef swap via the real `_baseRuleBackendRefsFor` lambda both branches; HelmRelease/EPP-CNP/VMServiceScrape shapes via lockstep mirror-lambdas (single-fixture strategy — the fixture carries canaries so endpointPicker cannot be enabled through `items`); latch-orthogonal-to-backend-type. The canary+endpointPicker and endpointPicker-without-gateway rejections are XRD-CEL (not kcl-testable) — documented in the test block and covered by e2e T012 (FR-004, FR-005, FR-006).

### Phase 3: e2e (feature-branch cluster)

- [ ] **T009**: e2e SC-001/SC-002 — enable `endpointPicker` on `xplane-qwen-coder`; verify HelmRelease/InferencePool/EPP owned by the XR, base rule points at the InferencePool, chat completion returns 200. Also assert `model: MoM` and every non-endpointPicker model still resolve unchanged, and `apps/base/ai/llm/ai-gateway-routes/route.yaml` is untouched (FR-011).
- [ ] **T010**: e2e SC-005 + CL-7 confirmation — `hubble observe --pod llm/<epp-pod> --verdict DROPPED` clean under load; confirm the EPP pod is admitted to PSS=restricted `llm` (resolves the Open question / [NEEDS CLARIFICATION]); document the actual EPP securityContext in the README.
- [ ] **T011**: e2e SC-006 — scale `xplane-qwen-coder` to ≥2 replicas, send ≥50 prefix-sharing requests, verify non-uniform per-pod distribution via EPP picker metrics + per-pod `vllm:num_requests_running`, and that vmagent scrapes EPP metrics (`up{...epp...}==1`); optional TTFT-vs-round-robin comparison.
- [ ] **T012**: e2e SC-003 — apply claims that violate the two CEL guards; capture both admission rejections.

### Phase 4: Validation & Documentation

- [x] **T013**: `examples/inferenceservice-endpointpicker.yaml` added and renders the full EPP set (HelmRelease + EPP CNP + EPP VMServiceScrape + InferencePool-backed AIGatewayRoute) via `kcl run` against the local module. NOTE: the composition's `crossplane render` pulls the KCL module from the OCI tag `0.8.0-pr1559` (republished on push by `crossplane-modules.yml`), which predates these changes — so `crossplane render` still exercises the pre-SPEC-004 module (renders cleanly, no regression to unmigrated behavior). The endpointPicker render is proven via `kcl run` of the example until the tag is republished on push (per Implementation Notes: "verify anonymous pull of the republished tag before pointing the composition at it").
- [x] **T014**: syntax + render stages of `./scripts/validate-kcl-compositions.sh` pass for inference-service (KCL syntax valid; basic + complete render successfully); the stage-1 format check reports "reformatted" ONLY because the working tree is dirty with the SPEC-004 diff (`kcl fmt` is idempotent — a second run reformats nothing, exit 0). `kcl test . -Y settings-example.yaml` green: 44/44 (was 38; +6 SPEC-004). Polaris/kube-linter run inside `crossplane render` context (stale OCI module) — full Polaris ≥85 gate on the republished tag is an e2e/CI concern.
- [x] **T015**: README.md (endpointPicker section: N=1 vs N>1 payoff, canary exclusivity, EPP CNP surface, metrics, PSS=restricted posture + the deferred on-cluster finding; API summary; Resources-rendered table), `settings-example.yaml` (endpointPicker note explaining the canary mutual-exclusion), and `examples/inferenceservice-endpointpicker.yaml` added. The on-cluster PSS finding is filled in from T010 post-deploy.

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <2026-07-12> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific (round-robin destroys vLLM prefix-cache locality + load-blindness; EPP scores per request on the same signals)
- [x] User stories capture real user needs (US-1 prefix-cache-aware routing, US-2 self-contained opt-in + GC, US-3 secure picker pod)
- [x] Acceptance scenarios are testable (each maps to an SC with a concrete kubectl/hubble/metric check)
- [x] Scope is well-defined (Non-Goals: canary-through-InferencePool, cross-model pool, plugin tuning, fleet migration, version bump)
- [x] Success criteria are measurable (SC-001…007, falsifiable per validator)

### Platform Engineer

- [x] Design follows existing patterns (extends the SPEC-002 `gateway` block in place; reuses the `ocds` readiness latch and the App-composition HelmRelease RBAC grant)
- [x] API is consistent with other compositions (nested opt-in `enabled` sub-block, mirrors `gateway`/`route`/`preload` style)
- [x] Resource naming follows `xplane-*` convention (all EPP resources inherit the `xplane-*` claim name, suffix `-epp`)
- [x] KCL avoids mutation pattern (base-rule backendRef chosen by inline conditional — Implementation Notes; function-kcl #285)
- [x] Examples provided (basic stays endpointPicker-off; a dedicated endpointPicker example — separate from the canary example since the two are exclusive — T013/T015)

### Security & Compliance

- [x] Zero-trust networking (this feature ADDS a pod → a new default-deny EPP CiliumNetworkPolicy + serving-CNP ingress extension is REQUIRED — FR-007/CL-6/T005; NOT N/A)
- [x] Least-privilege RBAC (aggregate ClusterRole adds exactly `inferencepools`; `helmreleases` reused; `ocirepositories` deliberately NOT added — FR-009/T001; EPP's own pod-watch RBAC ships with the chart, namespace-scoped)
- [x] Secrets via External Secrets (EPP requires no credentials — no new secrets)
- [x] Security context enforced (EPP pod MUST satisfy PSS=restricted — FR-008/CL-7/T007; chart exposes no securityContext key, so enforcement path + on-cluster confirmation are explicit, NOT assumed)
- [x] IAM policies scoped to `xplane-*` resources (N/A — no AWS resources touched; EPP is in-cluster only)

### SRE

- [x] Health checks defined (EPP Deployment ships chart probes; route readiness derived from the `AIGatewayRoute` `Accepted` condition, unchanged)
- [x] Observability configured (EPP metrics scraped via composition-rendered VMServiceScrape — FR-010/CL-8/T006; routing effect observable via EPP picker metrics + per-pod `vllm:num_requests_running` — SC-006)
- [x] Resource requests + limits appropriate (chart EPP defaults: requests cpu 4 / mem 8Gi, limit mem 16Gi — Non-Goal to retune in v1; documented in README so operators size GPU-node headroom)
- [x] Failure modes documented (CEL admission rejections for both guards; InferencePool routing at N=1 is a functional no-op; latch prevents route flapping; `failureMode: FailOpen` chart default keeps traffic flowing if EPP is unavailable)
- [x] Recovery / rollback path clear (`endpointPicker.enabled: false` reverts the base rule to the AIServiceBackend chain and GCs the EPP resources — single-field revert, Implementation Notes)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition: `infrastructure/base/crossplane/configuration/kcl/inference-service/` (this module, v0.8.0) — SPEC-002 `gateway` block extended here
- Rules: `.claude/rules/cilium-network-policies.md` (DNS L7 / host-entity traps), `.claude/rules/crossplane-validation.md` (v2 traps: aggregate RBAC #3, informer stall #4), `.claude/rules/kcl-crossplane.md`
- GAIE `inferencepool` chart v1.5.0 values (verified): <https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/config/charts/inferencepool/values.yaml>
- Envoy AI Gateway AIGatewayRoute + InferencePool: <https://aigateway.envoyproxy.io/docs/capabilities/inference/aigatewayroute-inferencepool/>
