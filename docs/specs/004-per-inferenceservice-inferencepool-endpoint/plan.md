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
- [ ] Aggregate ClusterRole grant for `inference.networking.k8s.io/inferencepools` added to `infrastructure/base/crossplane/providers/additional-rbac.yaml`; `helmreleases` grant already present (App composition block) — reuse. `ocirepositories` NOT needed (shared source, CL-2). Crossplane v2 trap #3.
- [ ] PSS=restricted for the EPP pod — chart exposes no `securityContext` value key; enforcement path per CL-7 (verify on-cluster).

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

- [ ] **T001**: Add aggregate ClusterRole rule for `inference.networking.k8s.io/inferencepools` (+`/status`) to `additional-rbac.yaml`; confirm `helmreleases` already granted; verify with `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list inferencepools -A` and `... list helmreleases -A` (FR-009).
- [ ] **T002**: XRD: add `gateway.endpointPicker.{enabled}` schema + the two CEL validations (endpointPicker⇒gateway.enabled; endpointPicker ⊻ canaries) (FR-002, FR-005).

### Phase 2: Implementation

- [ ] **T003**: KCL: render per-claim `HelmRelease` `<name>-epp` (chart `inferencepool` via `chartRef` → `llm`/`inferencepool` OCIRepository) with the verified values (`modelServers.matchLabels`, `targetPorts`, `modelServerType`, `apiVersion`, `provider.name: none`) under `_endpointPickerEnabled` (FR-001, FR-003, CL-2, CL-5).
- [ ] **T004**: KCL: switch the `AIGatewayRoute` base-rule `backendRefs` to the InferencePool ref when endpointPicker is on, via inline conditional; keep `loraAdapters[]` pin rules and the readiness latch unchanged (FR-004, FR-006, CL-3).
- [ ] **T005**: KCL: render the EPP `CiliumNetworkPolicy` `<name>-epp` (egress vLLM:8000, kube-apiserver, kube-dns+rules.dns; ingress ext-proc:9002 from Envoy data plane) and extend the serving CNP to allow EPP ingress on :8000 (FR-007, CL-6).
- [ ] **T006**: KCL: render the EPP `VMServiceScrape` `<name>-epp` selecting the EPP Service (FR-010, CL-8).
- [ ] **T007**: KCL: implement PSS=restricted enforcement for the EPP pod per the CL-7 decision (chart override path or Kyverno mutate) (FR-008, CL-7).
- [ ] **T008**: `main_test.k`: endpointPicker on → HelmRelease + CNP + VMServiceScrape rendered and base rule carries the InferencePool backendRef; endpointPicker off → SPEC-002 AIServiceBackend rule unchanged, no EPP resources; canary+endpointPicker rejected (CEL fixture); route withheld when Deployment unready in the endpointPicker path and latched thereafter; naming `xplane-*` (FR-004, FR-005, FR-006).

### Phase 3: e2e (feature-branch cluster)

- [ ] **T009**: e2e SC-001/SC-002 — enable `endpointPicker` on `xplane-qwen-coder`; verify HelmRelease/InferencePool/EPP owned by the XR, base rule points at the InferencePool, chat completion returns 200. Also assert `model: MoM` and every non-endpointPicker model still resolve unchanged, and `apps/base/ai/llm/ai-gateway-routes/route.yaml` is untouched (FR-011).
- [ ] **T010**: e2e SC-005 + CL-7 confirmation — `hubble observe --pod llm/<epp-pod> --verdict DROPPED` clean under load; confirm the EPP pod is admitted to PSS=restricted `llm` (resolves the Open question / [NEEDS CLARIFICATION]); document the actual EPP securityContext in the README.
- [ ] **T011**: e2e SC-006 — scale `xplane-qwen-coder` to ≥2 replicas, send ≥50 prefix-sharing requests, verify non-uniform per-pod distribution via EPP picker metrics + per-pod `vllm:num_requests_running`, and that vmagent scrapes EPP metrics (`up{...epp...}==1`); optional TTFT-vs-round-robin comparison.
- [ ] **T012**: e2e SC-003 — apply claims that violate the two CEL guards; capture both admission rejections.

### Phase 4: Validation & Documentation

- [ ] **T013**: Basic + endpointPicker examples render with `crossplane render`.
- [ ] **T014**: `./scripts/validate-kcl-compositions.sh` exit 0 (incl. Polaris ≥ 85); `kcl test` suite green (FR-004 rendering, FR-005 CEL fixtures).
- [ ] **T015**: README.md, `settings-example.yaml`, examples updated (endpointPicker section: N=1 vs N>1 payoff, canary exclusivity, EPP CNP surface, metrics, the on-cluster PSS finding from T010).

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
