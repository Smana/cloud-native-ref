# ADR-0003: Use vLLM Production Stack over KServe + llm-d for v1 LLM Platform

**Status**: Accepted
**Date**: 2026-04-30
**Deciders**: Smana (Platform Owner)
**Related Spec**: [Self-Hosted LLM Platform with Cascade Routing](../plans/self-hosted-ai/02-spec-draft.md)

---

## Context

The self-hosted LLM Platform initiative (branch `wip/self-hosted-ai-draft`)
needs an inference orchestration layer to:

- Serve four open-weights models (Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen-7B, LlamaGuard 3-1B)
- Route requests intelligently across tier (small / medium / large) and specialty (general / code / guardrail)
- Scale individual models to zero when idle (cost control on a single L4 GPU NodePool capped at `nvidia.com/gpu: 4`)
- Run inside the existing Cilium / Tailscale / Flux GitOps stack

Two architectures dominated the 2026-Q1 ecosystem when this spec was drafted:

1. **vLLM Production Stack** — vLLM-native router + LMCache, opinionated for vLLM-only fleets.
2. **KServe v0.16 `LLMInferenceService` + llm-d Endpoint Picker** — generic ModelMesh-style abstraction with prefix-cache-aware routing, multi-tenant fairness, and federated multi-cluster support.

A decision is needed before Phase 2 (Inference Stack Install) so that the Helm chart, observability, and routing semantics stay consistent across phases.

---

## Decision Drivers

- **Operational simplicity** — fewer moving control planes is preferred for a single-cluster lab.
- **Avoid double-Envoy** — Cilium already runs Envoy as the L7 proxy for Gateway API; adding another Envoy layer (KServe + Inference Gateway) doubles the operational surface.
- **Reuse the existing Crossplane / KCL composition pattern** rather than introducing a new XRD ecosystem (KServe CRDs).
- **Constitution alignment** — solution must wire through Cilium GW API, External Secrets, EKS Pod Identity, VictoriaMetrics, default-deny CiliumNetworkPolicies.
- **Roadmap optionality** — easy migration if the multi-tenant or multi-cluster value of llm-d becomes real later.

---

## Considered Options

### Option 1: vLLM Production Stack + vLLM Semantic Router (Iris)

The vLLM project's own production reference: a router HelmRelease + per-model
serving engines + LMCache for KV-cache offload + a separate `vllm-semantic-router`
("Iris" v0.1, January 2026) for classifier-driven routing with built-in
jailbreak / PII / semantic-cache plugins.

**Pros**:
- One project family, one issue tracker, one cadence — vLLM team owns the whole stack.
- No Knative dependency.
- Iris ships first-class jailbreak + PII + semantic-cache plugins (CL-2 wires
  LlamaGuard as post-filter on top).
- Hybrid routing (CL-1 C: classifier → cascade-within-tier) is supported natively.
- Helm-based; integrates cleanly with the existing Flux / OCIRepository pattern.

**Cons**:
- Locked in to vLLM as the only serving engine (no SGLang, no TGI, no Triton without rework).
- Iris v0.1 — younger project surface; less prior art than KServe.
- Routing is centralized in one router pod; no per-Service routing fairness.
- Prefix-cache routing is per-LMCache pool, not the global prefix-aware router that llm-d offers.

### Option 2: KServe v0.16 `LLMInferenceService` + llm-d Endpoint Picker

The KServe + llm-d pair is the SOTA architecture as of Red Hat's 2026-04
write-up, with prefix-cache-aware routing claimed at ~57× P90 TTFT improvement
on shared-prefix workloads.

**Pros**:
- Best-in-class routing for shared-prefix workloads.
- Multi-engine (vLLM, SGLang, TGI) via the KServe abstraction.
- Multi-cluster + multi-tenant fairness primitives if the platform grows that direction.

**Cons**:
- KServe **Serverless mode** depends on Knative — a major control plane to install, operate, and upgrade. Adds 5+ Pods and a webhook chain that this repo does not currently run.
- llm-d adds a second Envoy proxy on top of Cilium's. Two L7 proxies = double the failure modes and observability cost.
- KServe CRDs are a new XRD ecosystem; doesn't compose with the existing `App` / `SQLInstance` / `EPI` Crossplane patterns without bridging.
- Operational surface dwarfs the v1 brief: four models on one cluster does not exercise the multi-tenant / multi-cluster value proposition.
- Less integration with vLLM-Semantic-Router-style classifier plugins; routing is prefix-cache-only.

### Option 3: Roll our own (Crossplane composition + raw vLLM Deployments + custom router)

Skip both upstream stacks; the InferenceService Crossplane composition would
render Deployments + Services + a small custom router.

**Pros**:
- Zero external dependencies.
- Tightly aligned with the existing composition pattern.

**Cons**:
- Reinvents Iris (classifier, jailbreak/PII, semantic cache) at material cost.
- No prior art for ops, monitoring, or upgrades.
- Defeats the point of a *reference* repo (showcase value lives in stitching upstream components, not building bespoke ones).

---

## Decision Outcome

**Chosen option**: **Option 1 — vLLM Production Stack + vLLM Semantic Router (Iris).**

**Rationale**:

The double-Envoy stack (Cilium Envoy + Inference Gateway Envoy) and the Knative
dependency in KServe Serverless mode are the load-bearing reasons against
Option 2. At four models on one cluster, llm-d's multi-tenant and federation
features have no concrete consumer — the operational cost is paid up front for a
benefit that may never materialise.

vLLM Production Stack reads as a clean, Flux-friendly fit for the existing
stack. Iris's classifier + plugins map directly to the Hybrid routing decision
(CL-1 C) and the post-filter LlamaGuard wiring (CL-2 A).

The migration path stays clean: vLLM Production Stack's routing keys + LMCache
prefix pools are the same primitives llm-d uses internally. If the platform
later grows to multi-cluster or multi-tenant, the per-model `InferenceService`
XR contract abstracts the underlying serving stack — switching to KServe + llm-d
becomes a composition rewrite, not a per-claim change.

---

## Consequences

### Positive

- One project family to learn / monitor / upgrade.
- No Knative — keeps the Cilium GW API + Tailscale + Flux story coherent.
- Iris built-in plugins (jailbreak, PII, semantic cache) eliminate input-side guardrail engineering.
- Composes cleanly with the existing Crossplane + KCL pattern (`InferenceService` XRD).

### Negative

- **vLLM lock-in for serving** — adopting SGLang or TGI later requires rework. Mitigation: the `InferenceService` XR's `image.repository` field already lets per-claim image override; and Iris speaks the OpenAI Chat Completions API, so any OpenAI-compatible engine remains addressable behind it.
- **Iris v0.1 maturity** — project surface is young (Jan 2026 release). Mitigation: Promptfoo nightly evals (CL-4 A) catch routing regressions inside 24h.
- **No global prefix-cache-aware routing** — workload patterns with very long shared system prompts will leave performance on the table compared to llm-d. Mitigation: enabled `prefixCache.enabled: true` per-model (LMCache local pool); revisit only if SC-004 latency targets miss.

### Neutral

- Prefix caching is per-pod LMCache rather than fleet-global. Acceptable for the v1 model count and traffic profile.
- The `vllm-production-stack-router` Service exists alongside `vllm-semantic-router` — two router-shaped services. Documented; the public HTTPRoute targets the Semantic Router only.

---

## Implementation Notes

The decision is already realised on branch `wip/self-hosted-ai-draft`:

- Phase 2 (`c60df37c`/`8b8c76b4`/`19c6b108`): KEDA HelmRelease, vLLM Production Stack HelmRelease, vLLM Semantic Router HelmRelease (initial classifier-only config).
- Phase 3 (`5d50245d`): `InferenceService` Crossplane composition that backs each model claim.
- Phase 5 (`0d569425`): Hybrid routing config (CL-1 C) + post-filter LlamaGuard (CL-2 A) + four-model fleet + public HTTPRoute.

**Trigger to revisit this ADR**:
- The platform grows to multi-cluster or multi-tenant requirements.
- KServe + llm-d ships an operator that drops the Knative dependency.
- vLLM upstream signals a shift away from Production Stack as the recommended deployment path.

---

## References

- Spec: [`docs/plans/self-hosted-ai/02-spec-draft.md`](../plans/self-hosted-ai/02-spec-draft.md)
- Plan §6 "Alternatives considered": [`docs/plans/self-hosted-ai/03-plan-draft.md`](../plans/self-hosted-ai/03-plan-draft.md)
- vLLM Production Stack: <https://github.com/vllm-project/production-stack>
- vLLM Semantic Router (Iris) release notes: <https://vllm.ai/blog/vllm-sr-iris>
- KServe v0.16 LLMInferenceService: <https://kserve.github.io/website/master/modelserving/v1beta1/llm/>
- llm-d Endpoint Picker: <https://github.com/llm-d/llm-d>
- Red Hat 2026-04 write-up on prefix-cache-aware routing
