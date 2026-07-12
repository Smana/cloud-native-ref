# Spec: Per-InferenceService InferencePool + Endpoint Picker (GAIE v1.5.0) smart routing behind Envoy AI Gateway

**ID**: SPEC-004
**Issue**: [#1570](https://github.com/Smana/cloud-native-ref/issues/1570)
**Status**: draft
**Type**: composition
**Created**: 2026-07-12
**Last updated**: 2026-07-12

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (which also tracks tasks and the review checklist); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Add an opt-in `spec.gateway.endpointPicker` block to the InferenceService composition (KCL, unreleased v0.8.0 — same module and PR as SPEC-002/003) that renders, per claim, a Gateway API Inference Extension (GAIE) v1.5.0 **InferencePool** + **Endpoint Picker (EPP)** and re-points the claim's `AIGatewayRoute` base rule at that InferencePool. This replaces the claim Service's round-robin ClusterIP load-balancing with vLLM-aware, KV-cache- and queue-depth-scored endpoint selection — prefix-cache-aware routing that only pays off once a model scales to N>1 replicas but wires cleanly at N=1 today.

---

## Problem

Traffic through the AI Gateway today reaches a model via the claim's ClusterIP `Service` (SPEC-002: `AIGatewayRoute → AIServiceBackend → Backend → <claim>.<ns>.svc:8000`). A Kubernetes Service load-balances **round-robin across replicas**, which is adversarial to vLLM: it scatters requests that share a prompt prefix across different pods, destroying each pod's automatic prefix-cache locality and forcing redundant prefill compute. It is also blind to per-pod load — a request can be sent to a replica whose KV-cache is saturated and whose queue is deep while a warm, idle replica sits next to it.

GAIE's Endpoint Picker (EPP) closes this gap: it scrapes the same vLLM `/metrics` the platform already collects (`vllm:num_requests_running`, `vllm:gpu_cache_usage_perc`, running/`max-num-seqs` saturation, LoRA adapter presence) and, per request, scores every candidate pod on queue depth + KV-cache utilization + prefix-cache affinity + LoRA-awareness, then routes to the best endpoint. InferencePool reached **v1 GA in 2025-09**; **v1.5.0 (2026-04)** adds flow control and a latency predictor. Published measurements from llm-d report up to **57× TTFT improvement over round-robin** under load. This complements — does not replace — the SPEC-001 KEDA autoscaler: KEDA reacts on the scale of tens of seconds (add/remove replicas), EPP reacts per-request in milliseconds (which existing replica), both reading the same vLLM saturation signals.

The mechanism is already **sourced but instantiated nowhere**: `flux/sources/ocirepo-inferencepool.yaml` pins the GAIE `inferencepool` Helm chart v1.5.0 in the `llm` namespace, and the InferencePool CRDs are installed via `crds/base/kustomization-inference-extension.yaml`. What is missing is the composition wiring that turns it on per model, gates route ownership on the composition's existing readiness latch, and satisfies the platform's zero-trust and PSS=restricted constraints for the new EPP pod.

---

## User Stories

### US-1: Prefix-cache-aware routing for a scaled model (Priority: P1)

As a **platform user running a model at N>1 replicas**, I want **the gateway to pick the best-loaded vLLM replica per request instead of round-robin**, so that **prefix-cache locality is preserved and TTFT drops under concurrent load without any client change**.

**Acceptance Scenarios**:
1. **Given** an InferenceService claim with `gateway.enabled: true` and `gateway.endpointPicker.enabled: true` scaled to ≥2 replicas, **When** OpenAI-compatible requests for its model name arrive, **Then** they are routed by the EPP (verifiable: EPP `inference_extension` picker metrics increment and select among the claim's own pods) rather than uniformly across replicas.
2. **Given** the same claim, **When** the model serves at N=1, **Then** routing still succeeds end-to-end through the InferencePool (EPP is a functional no-op with one endpoint) and no request 404s/503s.

### US-2: Self-contained, opt-in per claim (Priority: P1)

As a **platform maintainer**, I want **the InferencePool + EPP rendered and garbage-collected by the InferenceService composition behind an opt-in flag**, so that **enabling smart routing for a model is one field, deleting the model removes the picker, and models without the flag keep the SPEC-002 Service-backed routing unchanged**.

**Acceptance Scenarios**:
1. **Given** a claim with `endpointPicker.enabled: true`, **When** it becomes Ready, **Then** a `HelmRelease` (chart `inferencepool` v1.5.0), the InferencePool CR, and the EPP Deployment/Service exist with `ownerReferences` to the XR, and the `AIGatewayRoute` base rule's `backendRefs` point at the InferencePool (group `inference.networking.k8s.io`, kind `InferencePool`).
2. **Given** the claim is deleted, **When** Crossplane garbage-collects, **Then** the HelmRelease (and the InferencePool + EPP it installed) are removed; the shared `llm`-namespace OCIRepository is untouched.
3. **Given** a claim with `endpointPicker.enabled` unset, **When** it is applied, **Then** no InferencePool/EPP/HelmRelease is rendered and the route keeps the SPEC-002 `AIServiceBackend` chain verbatim.

### US-3: Secure-by-default picker pod (Priority: P1)

As the **security owner**, I want **the EPP pod to satisfy default-deny CiliumNetworkPolicy and PSS=restricted**, so that **adding an inference-path component does not widen the cluster's blast radius**.

**Acceptance Scenarios**:
1. **Given** the EPP pod is running, **When** `hubble observe --pod llm/<epp-pod> --verdict DROPPED` is inspected under normal traffic, **Then** no legitimate EPP flow (ext-proc from the Envoy data plane, `/metrics` scrape of the claim's vLLM pods, kube-apiserver watch of pods/InferencePool) is dropped and nothing else is allowed.
2. **Given** the EPP pod spec, **When** it is admitted to the PSS=restricted `llm` namespace, **Then** admission succeeds (runAsNonRoot, no privilege escalation, seccompProfile RuntimeDefault, capabilities dropped).

---

## Requirements

### Functional

- **FR-001**: The composition MUST render a per-claim Flux `HelmRelease` (chart `inferencepool`, version pinned to the GAIE v1.5.0 source) when `spec.gateway.endpointPicker.enabled` is true, referencing the shared static `llm`-namespace `OCIRepository` `inferencepool` via `chartRef` (same-namespace) — CL-2. Default MUST be off (opt-in).
- **FR-002**: `spec.gateway.endpointPicker.enabled` MUST require `spec.gateway.enabled` (XRD CEL rejects endpointPicker without gateway) — CL-1.
- **FR-003**: The rendered HelmRelease values MUST scope the InferencePool to the claim's **own** replicas only — `inferencePool.modelServers.matchLabels: {app.kubernetes.io/name: <claim>}` — never cross-model (CL-5), with `inferencePool.targetPorts: [{number: 8000}]`, `inferencePool.modelServerType: vllm`, `inferencePool.apiVersion: inference.networking.k8s.io/v1`, and `provider.name: none` (verified chart value keys — CL-2).
- **FR-004**: When `endpointPicker.enabled` is true, the `AIGatewayRoute` base rule (`x-ai-eg-model: <claim>`) `backendRefs` MUST reference the InferencePool (`group: inference.networking.k8s.io`, `kind: InferencePool`, `name: <claim>`) instead of the `AIServiceBackend` chain; the per-`loraAdapters[]` pin rules MUST be preserved unchanged (SPEC-002 FR-004) — CL-3.
- **FR-005**: XRD CEL validation MUST reject `endpointPicker.enabled: true` together with any `gateway.canaries[]` entry — weighted LoRA canaries and InferencePool routing are mutually exclusive in this version because an InferencePool backendRef supports neither `weight` nor `modelNameOverride` and only one InferencePool is allowed per rule (CL-4). Canary claims keep the SPEC-002 AIServiceBackend routing.
- **FR-006**: The `AIGatewayRoute` MUST remain withheld until the claim's Deployment reports `Available=True` and MUST NOT be withdrawn on transient unavailability once created (SPEC-002 FR-002 readiness latch MUST still gate the route regardless of endpointPicker state) — CL-3.
- **FR-007**: A CiliumNetworkPolicy MUST govern the EPP pod (default-deny + explicit allow): egress to the claim's vLLM pods on `8000` (`/metrics` scrape + endpoint health), egress to kube-apiserver (EPP watches Pods + InferencePool), egress to kube-dns:53 with `rules.dns` L7 inspection; ingress from the Envoy AI Gateway data-plane pods on the ext-proc port `9002`. The claim's serving CNP MUST additionally allow ingress from the EPP pod on `8000` (CL-6).
- **FR-008**: The EPP pod MUST satisfy PSS=restricted (`runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` where the image permits, `seccompProfile.type: RuntimeDefault`, `capabilities: drop [ALL]`) with resource requests + limits set. Because the GAIE v1.5.0 `inferencepool` chart does **not** expose a `securityContext` value key (verified: EPP Deployment comes from the shared `inference-extension.deployment` library helper), the enforcement mechanism is deferred to CL-7 with an e2e admission-verification task.
- **FR-009**: The Crossplane aggregate ClusterRole MUST grant the kinds the composition now renders — `helm.toolkit.fluxcd.io/helmreleases` (already granted for App composition; confirm reuse) and `inference.networking.k8s.io/inferencepools` (new) — plus `source.toolkit.fluxcd.io/ocirepositories` only if a per-claim OCIRepository is ever rendered (CL-2 chooses the shared source, so ocirepositories is NOT required) (FR — Crossplane v2 trap #3).
- **FR-010**: The EPP's own Prometheus metrics MUST be scraped — the composition MUST render a `VMServiceScrape` selecting the EPP Service when `endpointPicker.enabled` is true (or the HelmRelease MUST enable the chart's ServiceMonitor path and a matching VMServiceScrape) — CL-8.
- **FR-011**: Routing MUST stay functional for `model: MoM` (semantic router) and for every non-endpointPicker model — no change to unmigrated claims or to `apps/base/ai/llm/ai-gateway-routes/route.yaml`.

### Non-Goals

- Weighted LoRA canary **through** an InferencePool (blocked upstream: no `weight`/`modelNameOverride` on an InferencePool backendRef — CL-4). Canaries remain the SPEC-002 AIServiceBackend path; the two features are mutually exclusive per claim for now.
- Cross-model / shared InferencePool selecting endpoints across multiple claims (CL-5 scopes each pool to one claim's pods).
- Tuning EPP scheduling plugins (custom scorers, latency predictor, flow control) — defaults only in v1; `pluginsConfigFile: default-plugins.yaml`.
- Migrating existing fleet models to endpointPicker: this spec ships the capability; enabling it on `xplane-qwen-coder` (which becomes the e2e subject) is the only migration.
- Any composition module version bump: this lands in the **same PR** as SPEC-002/003 on the unreleased **v0.8.0** module (PR-tag `0.8.0-pr1559` republished on push) — no separate release.

---

## Success Criteria

Each criterion must be **falsifiable** — a human or `/verify-spec` must be able to answer yes/no with cluster evidence.

- **SC-001**: With `gateway: {enabled: true, endpointPicker: {enabled: true}}` on `xplane-qwen-coder`, the claim reaches `Synced=True`/`Ready=True`, and `kubectl get helmrelease,inferencepool,deploy -n llm -l app.kubernetes.io/name=xplane-qwen-coder` shows the HelmRelease, the InferencePool CR, and a running EPP Deployment, all with `ownerReferences` to the XR.
- **SC-002**: The `xplane-qwen-coder` `AIGatewayRoute` base rule's `backendRefs[0]` has `group: inference.networking.k8s.io`, `kind: InferencePool`, `name: xplane-qwen-coder`, and a chat completion for model `xplane-qwen-coder` through the gateway returns HTTP 200.
- **SC-003**: A claim applied with both `endpointPicker.enabled: true` and a `canaries[]` entry is rejected at admission with a CEL message naming the mutual-exclusion (FR-005); a claim with `endpointPicker.enabled: true` and `gateway.enabled` absent is also rejected (FR-002).
- **SC-004**: On a scratch claim, the `AIGatewayRoute` is absent while the Deployment is unready and appears within one reconcile of `Available=True`; deleting the claim removes the HelmRelease + InferencePool + EPP (and the AIGatewayRoute/Backend/AIServiceBackend where applicable), leaving `flux/sources/ocirepo-inferencepool.yaml` intact.
- **SC-005**: `hubble observe --pod llm/<epp-pod> --verdict DROPPED --last 100` shows no dropped legitimate EPP flow (ext-proc ingress from the Envoy data plane, `:8000` scrape egress to the claim's vLLM pods, kube-apiserver + kube-dns egress) under normal traffic, and the EPP pod is admitted to the PSS=restricted `llm` namespace (no admission denial).
- **SC-006**: With `endpointPicker.enabled: true` and the model scaled to ≥2 replicas, ≥50 requests bearing a shared prompt prefix are distributed **non-uniformly** across the claim's pods (EPP steers toward the prefix-warm/least-loaded endpoint), verifiable via EPP picker metrics and per-pod `vllm:num_requests_running`; the EPP's own metrics are scraped by vmagent (`up{job=~".*qwen-coder.*epp.*"} == 1`).
- **SC-007**: `./scripts/validate-kcl-compositions.sh` exits 0; `main_test.k` covers both rendering paths (endpointPicker on → HelmRelease + InferencePool-backed base rule; off → SPEC-002 AIServiceBackend rule unchanged), the canary-exclusion CEL, and that the readiness latch still gates the `AIGatewayRoute` in the endpointPicker path.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] [NEEDS CLARIFICATION: The GAIE v1.5.0 `inferencepool` chart does not expose a `securityContext` value key for the EPP Deployment (verified: rendered by the shared `inference-extension.deployment` library helper). Whether the upstream EPP image already runs non-root with a compliant context under PSS=restricted, and if not, whether a Kyverno mutate policy or a chart override path is required, is resolved conservatively in CL-7 and MUST be confirmed on-cluster in the e2e admission task (plan.md T010).]

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

- CL-1 — endpointPicker opt-in per claim (`gateway.endpointPicker.enabled`, default false), requires `gateway.enabled` via CEL.
- CL-2 — EPP delivered as a composition-rendered per-claim HelmRelease referencing the shared static `llm`-namespace OCIRepository (no per-claim OCIRepository; cross-namespace not needed).
- CL-3 — AIGatewayRoute base rule backendRef switches to the InferencePool when endpointPicker is on; pin rules + readiness latch unchanged.
- CL-4 — endpointPicker and `canaries[]` are mutually exclusive (CEL guard); InferencePool backendRefs carry no `weight`/`modelNameOverride`.
- CL-5 — each EPP/InferencePool selects only the claim's own pods (`app.kubernetes.io/name=<claim>`), never cross-model.
- CL-6 — new CiliumNetworkPolicy for the EPP pod + serving-CNP ingress extension for EPP `:8000` scrape.
- CL-7 — PSS=restricted enforcement for the EPP pod (chart exposes no securityContext key) — conservative decision + e2e admission check.
- CL-8 — EPP metrics scraped via a composition-rendered VMServiceScrape.

---

## References

- Plan: [plan.md](plan.md) — design, tasks, review checklist
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Predecessor (same PR/module): [SPEC-002 — Composition-owned AI Gateway routing](../002-composition-owned-gateway-routing/spec.md), SPEC-003 (engineArgs + servedModels)
- Related: [SPEC-001 — LLM platform prometheus autoscaling](../0001-llm-platform-prometheus-autoscaling/spec.md) (KEDA; complementary control loop)
- Verified current state: `flux/sources/ocirepo-inferencepool.yaml` (GAIE `inferencepool` chart v1.5.0, `llm` ns), `crds/base/kustomization-inference-extension.yaml` (InferencePool CRDs), `infrastructure/base/envoy-ai-gateway/gateway.yaml` (Gateway `ai-gateway`, HTTP/8080, AllowedRoutes from `llm`), `infrastructure/base/crossplane/providers/additional-rbac.yaml` (aggregate ClusterRole)
- Envoy AI Gateway InferencePool guide: <https://aigateway.envoyproxy.io/docs/capabilities/inference/aigatewayroute-inferencepool/> — backendRef `group: inference.networking.k8s.io`, `kind: InferencePool`; blog: <https://aigateway.envoyproxy.io/blog/endpoint-picker-for-inference-routing/>
- GAIE `inferencepool` chart values (v1.5.0): <https://github.com/kubernetes-sigs/gateway-api-inference-extension/blob/v1.5.0/config/charts/inferencepool/values.yaml>
