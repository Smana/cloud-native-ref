# Spec: Self-Hosted LLM Platform with Cascade Routing

**ID**: SPEC-NNN  *(auto-assigned by `create-spec.sh`)*
**Issue**: N/A  *(this draft predates `create-spec.sh`; the script will inject the real `#NNNN` when run)*
**Status**: draft
**Type**: composition
**Created**: 2026-04-26
**Last updated**: 2026-04-26

> The **spec** is the contract: *WHAT* we are delivering and *why*. Freeze it once approved. How we build it lives in [`plan.md`](plan.md) (phase map + cross-phase tasks) and per-phase plans under [`phases/`](phases/); decisions made during filling live append-only in [`clarifications.md`](clarifications.md).

---

## Summary

Deliver a Kubernetes-native self-hosted LLM serving platform on the existing EKS cluster (`mycluster-0`) with **cascade routing across multiple specialist models**, exposed only over Tailscale, fully integrated with the repo's Crossplane KCL composition pattern, OpenBao/External-Secrets, Cilium Gateway API, and VictoriaMetrics observability — eliminating dependence on hosted LLM APIs for internal use cases while showcasing April-2026 SOTA inference patterns.

---

## Problem

The platform team and internal users (engineers, on-call, blog/docs authoring assistants) currently depend on hosted LLM APIs (Anthropic / OpenAI / others) for code review, documentation drafting, troubleshooting, and operational summarization. This creates four problems:

1. **Data egress** — every prompt leaves the network boundary. Some prompts contain cluster topology, log lines, or in-progress secrets-rotation plans that we should not ship outside.
2. **Cost unpredictability** — token spend grows with usage with no per-team accounting in our current setup.
3. **Capability drift** — hosted models change underneath us; reproducibility of past answers is impossible without an audit trail.
4. **Reference gap** — `cloud-native-ref` is a teaching repo for cloud-native patterns; it lacks a worked example of an inference platform built the same way as `App` / `SQLInstance` / `EPI`. There is no canonical "this is how we run inference here" composition.

Without this spec, every internal LLM use case is either a hosted-API dependency or a one-off Helm install with no observability, no network isolation, no eval gate, and no cost accounting.

---

## User Stories

### US-1: Internal user invokes the cluster LLM endpoint without choosing a model (Priority: P1)

As an **internal engineer on the tailnet**, I want to **POST an OpenAI-compatible chat-completions request to a single endpoint** with `"model": "auto"`, so that **the platform routes my prompt to the cheapest model that can answer it correctly without my having to know which model is which**.

**Acceptance Scenarios**:
1. **Given** the user is connected to the Tailscale tailnet (`tag:k8s`), **When** they `POST /v1/chat/completions` to `llm.priv.cloud.ogenki.io` with `"model": "auto"` and a simple factual prompt, **Then** the response is served by the small-tier model (Phi-4 Mini), the response includes the actual model name in `model` field, and end-to-end latency p95 is under 3 seconds with the model warm.
2. **Given** the same user, **When** they send a prompt classified as code (e.g., "write a Rust function to parse CIDR"), **Then** the response is served by the code-specialist model (DeepSeek-R1-Distill-Qwen3-8B) and the routing decision is logged with the classifier signal.
3. **Given** a user not on the tailnet, **When** they attempt to reach `llm.priv.cloud.ogenki.io`, **Then** the request is dropped at the Cilium Gateway with no response (DNS resolution fails publicly).

### US-2: Platform engineer adds a new model to the fleet via a Crossplane claim (Priority: P1)

As a **platform engineer**, I want to **add a new self-hosted model by writing a single `XInferenceService` claim**, so that **I do not have to hand-roll Deployment + HPA + Service + HTTPRoute + VMServiceScrape + CiliumNetworkPolicy + EPI + ExternalSecret for every model**.

**Acceptance Scenarios**:
1. **Given** the `XInferenceService` XRD is installed and a GPU NodePool exists, **When** I `kubectl apply` a claim with `model.repository: meta-llama/Llama-Guard-3-1B` and `routing.tier: small`, **Then** within 10 minutes the model is reachable through the Semantic Router, has metrics scraped by VictoriaMetrics, has an EPI-scoped read of the model-weights S3 bucket, and is governed by a default-deny CiliumNetworkPolicy.
2. **Given** an existing model claim, **When** I delete it, **Then** the Deployment and Service are removed but S3-stored weights and IAM resources tagged `xplane-llm-*` follow the retention policy in ADR-0002 (no automatic IAM/S3 deletion).

### US-3: SRE confirms the platform survives idle cost (Priority: P2)

As an **SRE responsible for the AWS bill**, I want **GPU pods to scale to zero when idle and GPU nodes to terminate within the consolidation window**, so that **idle inference does not accumulate cost overnight**.

**Acceptance Scenarios**:
1. **Given** a model deployed with `scaling.scaleToZeroIdleSeconds: 600`, **When** no requests arrive for 10 minutes, **Then** the model's pods reach zero replicas and the GPU node hosting them is terminated by Karpenter within an additional 60 seconds.
2. **Given** a scaled-to-zero model, **When** the next request arrives, **Then** the cold-start path completes (Karpenter node + image pull from EBS snapshot + vLLM ready + first token) within 90 seconds.

### US-4: Quality engineer detects regression after a model swap (Priority: P2)

As a **quality engineer**, I want **a Promptfoo eval suite to run nightly against the routing endpoint and emit Prometheus metrics**, so that **a routing change or model swap that drops correctness on any category triggers an alert before users notice**.

**Acceptance Scenarios**:
1. **Given** a baseline pass-rate of `≥0.85` on the code category, **When** the deployed code-tier model is changed and pass-rate falls below `0.75`, **Then** a `VMRule` alert fires within one hour of the next eval run.

### US-5: Internal user sees jailbreak / PII / toxic-content prompts blocked (Priority: P2)

As a **platform owner**, I want **prompts matching jailbreak patterns or containing PII / toxic content to be blocked or redacted at the router**, so that **even internal users do not accidentally inject hostile prompts that destabilize the model fleet, and outbound responses do not contain content that violates internal policy**.

**Acceptance Scenarios**:
1. **Given** the Semantic Router with jailbreak + PII plugins enabled, **When** a request contains a known jailbreak pattern, **Then** the router returns HTTP 403 with a structured error and increments `vllm_semantic_router_blocked_total{reason="jailbreak"}`.
2. **Given** the LlamaGuard 3-1B post-filter, **When** a model output is classified unsafe, **Then** the response is replaced with a refusal message and the event is logged to VictoriaLogs.

---

## Requirements

### Functional

- **FR-001**: The system MUST expose an OpenAI-compatible endpoint (`/v1/chat/completions`, `/v1/responses`, `/v1/models`) at `llm.priv.cloud.ogenki.io`, reachable only via Tailscale (`tag:k8s` ACL).
- **FR-002**: The system MUST route requests with `"model": "auto"` to the model selected by the vLLM Semantic Router based on classifier signals (domain, keyword, embedding). Direct model selection by name MUST also work for explicit invocations.
- **FR-003**: The system MUST run at least four model deployments at general availability: Phi-4 Mini (`tier: small, specialty: general`), Qwen3-8B (`tier: medium, specialty: general`), DeepSeek-R1-Distill-Qwen3-8B (`tier: large, specialty: code`), LlamaGuard 3-1B (`tier: small, specialty: guardrail`).
- **FR-004**: The system MUST provide a Crossplane composite resource `XInferenceService` (KCL composition) that, given a model spec, provisions Deployment + KEDA ScaledObject + Service + HTTPRoute + VMServiceScrape + CiliumNetworkPolicy + EPI for S3 read + ExternalSecret for HF token.
- **FR-005**: The system MUST scale a model's pod count from zero to one within 90 seconds of the first request after idle (cold-start budget).
- **FR-006**: The system MUST scale a model's pod count to zero after a configurable idle window (default 600 seconds) and Karpenter MUST terminate the underlying GPU node within an additional 60 seconds.
- **FR-007**: The system MUST emit Prometheus metrics from each vLLM pod (`vllm:gpu_cache_usage_perc`, `vllm:num_requests_waiting`, `vllm:request_success_total`, `vllm:e2e_request_latency_seconds`) and from the Semantic Router (`vllm_semantic_router_latency_seconds`, `vllm_semantic_router_decisions_total{tier}`, `vllm_semantic_router_blocked_total{reason}`).
- **FR-008**: The system MUST run a Promptfoo eval CronJob nightly against the routing endpoint with a versioned eval suite of at least 50 prompts spanning the routing categories (general, code, guardrail), and emit `promptfoo_test_pass_rate{category}` to VictoriaMetrics.
- **FR-009**: The system MUST block prompts matching the Semantic Router jailbreak / PII plugins and MUST run LlamaGuard 3-1B as a post-filter on model output (per CL-2 placement decision).
- **FR-010**: The system MUST expose OpenWebUI behind the Tailscale Gateway at `chat.priv.cloud.ogenki.io`, configured to call the routing endpoint as its OpenAI-compatible backend.
- **FR-011**: All model weights MUST be cached in an S3 bucket (`xplane-llm-models`) and pulled via the EKS Pod Identity association created by the `EPI` XR (no IRSA, no long-lived credentials).
- **FR-012**: All AWS IAM resources created for this platform MUST be prefixed `xplane-llm-*` (constitution-mandated for IAM scoping).
- **FR-013**: The Grafana dashboard `llm-platform-cost` MUST display realized `$/hour` and `$ per 1M tokens` derived from `karpenter_nodes` × instance pricing × per-model token counters.

### Non-Goals

- Public-Internet exposure of any LLM endpoint (decided in upstream brainstorm; revisit only via new spec).
- Multi-tenancy with per-user quota enforcement (LiteLLM-proxy layer can be added later).
- Fine-tuning, LoRA hot-swap, or any training workload.
- RAG pipeline (vector DB, embedding service, retrieval) — separate spec.
- Multi-cluster federation; this targets single cluster `mycluster-0` only.
- Tensor-parallel multi-GPU per replica (TP=1 throughout; TP>1 deferred until ≥70B-class models are in scope).
- AWS Inferentia (`inf2`) backend; G6 / NVIDIA L4 only in v1.

---

## Success Criteria

Each criterion is **falsifiable** — measurable yes/no with a fresh command.

- **SC-001**: A pod requesting `nvidia.com/gpu: 1` schedules on the new `gpu-l4` Karpenter NodePool within 90 seconds of submission, returning a non-empty `nvidia-smi` output. Verified by `kubectl run gpu-smoke ... -- nvidia-smi`.
- **SC-002**: After 600 seconds of zero traffic to a deployed model, `kubectl get pods -l xinferenceservice=phi4-mini -n llm-platform` returns 0 pods AND `kubectl get nodes -l karpenter.sh/nodepool=gpu-l4` returns 0 nodes within an additional 60 seconds.
- **SC-003**: An OpenAI-client `POST /v1/chat/completions` with `"model": "auto"` and prompt `"Write a Rust function to parse CIDR ranges"` returns within 5 seconds (warm) with `model: "deepseek-r1-distill-qwen3-8b"` in the response body. Verified by `curl ... | jq .model`.
- **SC-004**: The Semantic Router routing decision adds no more than 200ms p95 measured by the histogram `vllm_semantic_router_latency_seconds_bucket{le="0.2"}` over a 1-hour window with sustained load (≥100 req/min).
- **SC-005**: A jailbreak prompt set of 10 patterns (drawn from the Iris reference plugin tests) is blocked by the Semantic Router with zero false negatives, recorded in `vllm_semantic_router_blocked_total{reason="jailbreak"}`.
- **SC-006**: A LlamaGuard 3-1B post-filter classifies the standard ToxiGen sample with precision at or above 0.95 against ground-truth labels, recorded by Promptfoo metric `llamaguard_precision`.
- **SC-007**: The nightly Promptfoo CronJob produces a results JSON in S3 (`xplane-llm-eval-results/<date>.json`) and the metric `promptfoo_test_pass_rate{category="code"}` appears in VictoriaMetrics within 10 minutes of CronJob completion.
- **SC-008**: An intentional regression injection (forcing the code tier to route to Phi-4 Mini for 20% of code prompts) drops `promptfoo_test_pass_rate{category="code"}` below the configured threshold (default 0.75) and triggers `VMRule: LLMRoutingQualityDegraded` within one hour.
- **SC-009**: `./scripts/validate-kcl-compositions.sh inference-service` exits 0 (kcl fmt, kcl run, crossplane render, Polaris ≥ 85, kube-linter), AND `main_test.k` covers ≥6 resources rendered for a minimal claim and ≥10 resources for a full claim.
- **SC-010**: `./scripts/validate-spec.sh docs/specs/NNN-self-hosted-llm-platform/` exits 0 with zero errors before each phase PR is merged.
- **SC-011**: `aws iam simulate-principal-policy` against the IAM role created by the EPI XR `xplane-llm-models-s3-read` returns `allowed` only for `s3:GetObject` on `arn:aws:s3:::xplane-llm-models/*` and `denied` for any other action.
- **SC-012**: The Grafana dashboard `llm-platform-cost` panel `dollars_per_million_tokens` returns a value computed as `(sum(karpenter_nodes{nodepool="gpu-l4"}) * 0.3257) / (sum(rate(vllm:request_prompt_tokens_total[1h])) / 1e6)` and matches manual calculation within 5%.

---

## Open questions

<!-- Mark unresolved decisions here. Use /clarify to walk through each one.
Resolved decisions are appended to clarifications.md (never inlined here);
reference them by ID (CL-1, CL-2, ...) once resolved. -->

- [ ] [NEEDS CLARIFICATION: Should `model: auto` cascade tiny→mid→large on confidence, or hard-route by classifier? See CL-1 in clarifications.md.]
- [ ] [NEEDS CLARIFICATION: LlamaGuard 3-1B placement — pre-filter, post-filter, or both? See CL-2.]
- [ ] [NEEDS CLARIFICATION: Model weight preload trigger — auto on first claim, or manual per-model Job? See CL-3.]
- [ ] [NEEDS CLARIFICATION: Promptfoo eval cadence — nightly only, or per Flux reconciliation of an XInferenceService? See CL-4.]
- [ ] [NEEDS CLARIFICATION: Extend `App` XR with `gpu` field, or keep `App` strictly CPU and require `XInferenceService` for any GPU workload? See CL-5.]
- [ ] [NEEDS CLARIFICATION: `gpu-l4` NodePool capacity ceiling — hard cap on `nvidia.com/gpu` total per NodePool? See CL-6.]

<!-- Resolved questions appear below as `CL-N — <summary>` lines, appended by /clarify. -->

---

## References

- Plan: [plan.md](plan.md) — phase map, cross-phase design, review checklist
- Per-phase plans: [phases/](phases/) — `1-gpu-foundation/`, `2-inference-stack/`, `3-composition/`, `4-storage/`, `5-fleet-routing/`, `6-ui/`, `7-eval-guardrails-cost/`
- Clarifications: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADR-0001: [Use KCL for Crossplane Compositions](../../decisions/0001-use-kcl-for-crossplane-compositions.md)
- ADR-0002: [Use EKS Pod Identity over IRSA](../../decisions/0002-eks-pod-identity-over-irsa.md)
- ADR-0003 (proposed in this spec): vLLM Production Stack over KServe + llm-d for v1
- Phased spec guidance: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition (template for `XInferenceService`): [`infrastructure/base/crossplane/configuration/kcl/app/`](../../../infrastructure/base/crossplane/configuration/kcl/app/)
- Original draft (challenged): [`Self-Hosting LLMs on EKS Plan.md`](../../../Self-Hosting%20LLMs%20on%20EKS%20Plan.md)
