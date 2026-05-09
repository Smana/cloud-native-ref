# Self-Hosted LLM Platform — Plan v2 (April 2026)

> ⚠️ **Status**: Frozen historical draft. The autoscaling sub-design here
> (KEDA HTTP add-on / scale-from-zero / 3 always-warm) was superseded by
> [SPEC-001](../../specs/0001-llm-platform-prometheus-autoscaling/spec.md):
> KEDA `ScaledObject` with prometheus triggers on leading vLLM saturation
> metrics, all 4 models default `min=1`, no proxy hop. The bucket-only
> storage in §"Storage & IAM" was superseded by ADR-0004 (Amazon S3 Files
> POSIX mount). Other architecture choices (vLLM PS over KServe + llm-d,
> Iris router, Karpenter `gpu-l4` NodePool, Promptfoo evals) shipped as
> documented. See [`docs/architecture/README.md`](../../architecture/README.md)
> for the as-built state.

> Replaces `Self-Hosting LLMs on EKS Plan.md` (the doc you asked me to challenge).
> Tailored to **cloud-native-ref**: Cilium GW API + Tailscale + Crossplane KCL + OpenBao + VictoriaMetrics, deployed via SDD.

---

## 0. ⏸ PAUSED — Resumption Brief (saved 2026-04-26)

**Status**: Plan approved. SDD spec drafts written and validated. Stopped before any implementation, before `create-spec.sh` ran (no GitHub issue created), before any cluster change.

**Where everything lives**:

| Artifact | Path | Status |
|---|---|---|
| Master plan (this file) | `~/.claude/plans/i-want-you-to-stateful-orbit.md` | Approved, frozen |
| Original doc (challenged) | `cloud-native-ref/Self-Hosting LLMs on EKS Plan.md` | Untracked, kept as reference |
| SDD `spec.md` draft | `~/.claude/plans/llm-platform-spec-draft/spec.md` | 13 FR-XXX + 12 SC-XXX, validates clean |
| SDD `plan.md` draft | `~/.claude/plans/llm-platform-spec-draft/plan.md` | 7-phase phased plan, 44 T-IDs, 20/20 review checklist |
| SDD `clarifications.md` draft | `~/.claude/plans/llm-platform-spec-draft/clarifications.md` | 6 CL-N entries pre-framed with recommendations |

**Validation state**: `./scripts/validate-spec.sh /home/smana/.claude/plans/llm-platform-spec-draft/` → 2 warnings, 0 errors. Warnings are: (1) 6 unresolved `[NEEDS CLARIFICATION]` markers (expected — they are the `/clarify` agenda); (2) `Issue: N/A` (expected — `create-spec.sh` will inject the real issue number).

**To resume**:

1. Read this file + the three drafts under `~/.claude/plans/llm-platform-spec-draft/`.
2. Decide on the 6 CL-N options (recommendations are in the draft `clarifications.md`).
3. When ready to commit to a GitHub issue, run from the repo root:
   ```bash
   ./scripts/sdd/create-spec.sh composition "self-hosted LLM platform with cascade routing and intelligent model selection"
   ```
   This creates `docs/specs/NNN-self-hosted-llm-platform/{spec,plan,clarifications}.md` from templates AND opens a public GitHub issue. Capture the printed `spec_dir=...` and `issue_num=...`.
4. Copy the drafted content from `~/.claude/plans/llm-platform-spec-draft/*.md` over the script-generated files, **but preserve the auto-injected `**Issue**: #NNNN` line** (the script substitutes `#XXX` → real issue number; if you keep your `**Issue**: N/A` line, the spec loses traceability to its issue).
5. Re-run `./scripts/validate-spec.sh docs/specs/NNN-self-hosted-llm-platform/` — should be 0 errors, 1 warning (still the 6 unresolved CL markers; resolves as `/clarify` updates them).
6. Begin Phase 1: write `infrastructure/base/karpenter-nodepools/gpu-l4-{nodepool,ec2nodeclass}.yaml` per `plan.md` T001-T005.

**What was NOT done**:
- No GitHub issue created.
- No files written to the repo (only to `~/.claude/plans/` and `/tmp` which has been moved to `~/.claude/plans/`).
- No `git commit`.
- No cluster change (Karpenter, Flux, kubectl all untouched).
- Per-phase plan.md files under `phases/N-name/plan.md` — the root `plan.md` covers the full phase map; per-phase plans get drafted when each phase is picked up.
- ADR-0003 (vLLM PS over KServe + llm-d) — drafted in concept inside the master plan §3.3, but not yet a real `docs/decisions/0003-*.md` file.

**Decisions still owed by user (the 6 CL-N items)** — recommendations in the draft, but final call is yours:
1. **CL-1**: Cascade vs hard route vs hybrid. *Recommendation: hybrid.*
2. **CL-2**: LlamaGuard placement (pre / post / both). *Recommendation: post-filter only.*
3. **CL-3**: Model preload trigger (auto Job vs manual). *Recommendation: auto Job rendered by composition.*
4. **CL-4**: Promptfoo eval cadence (nightly vs per-reconciliation vs hybrid). *Recommendation: nightly.*
5. **CL-5**: Extend `App` XR with `gpu` block, or keep CPU-only. *Recommendation: keep `App` CPU-only.*
6. **CL-6**: `gpu-l4` NodePool capacity ceiling. *Recommendation: `nvidia.com/gpu: 8`.*

---

## 1. Context — why redo the plan

You asked for the **best self-hosted LLM platform**, with **intelligent routing** to the right model, deeply integrated with **this repo**. The existing `Self-Hosting LLMs on EKS Plan.md` is generally well-researched (sub-10B model trade-offs, GPU economics, Karpenter spot patterns), but it was written **as if the cluster were green-field**. Once cross-checked against the actual repo, ~40% of its concrete recommendations either duplicate or contradict what's already deployed. It also misses the routing/multi-model story you specifically asked for.

This plan keeps the good parts (model selection, vLLM, Karpenter spot, EBS snapshot warmup), discards the duplicated parts, and adds the SOTA-2026 layer the original doc never mentioned: **vLLM Production Stack + vLLM Semantic Router v0.1 "Iris"** for prefix-cache-aware + classifier-driven routing, fronted by KEDA HTTP scale-to-zero.

---

## 2. Deep critique of the existing doc

### 2.1 Concrete deltas vs actual repo state

| Existing doc proposes | Repo already has | Verdict |
|---|---|---|
| **NGINX Ingress Controller + NLB** | Cilium Gateway API + `loadBalancerClass: tailscale` + `platform-tailscale-general` Gateway (`infrastructure/base/gapi/`) | **Discard NGINX.** Use existing `parentRefs: platform-tailscale-general` (apps/observability/tooling namespaces already allowed). |
| **OAuth2 Proxy + GitHub SSO** | Tailscale device auth (`tag:k8s`) + Zitadel OIDC for app-level (`security/base/zitadel/`) | **Discard OAuth2 Proxy.** Tailscale already handles edge identity via ACL; Zitadel handles app-layer OIDC. |
| **Bitnami Sealed Secrets / direct AWS SM** | External Secrets Operator + AWS Secrets Manager + OpenBao AppRole (`security/base/cert-manager/`, `app-definition.yaml` `externalSecrets` field) | **Discard Sealed Secrets.** Pattern: ExternalSecret → AWS Secrets Manager path → mounted as env. HF_TOKEN follows same. |
| **Prometheus + Grafana** generic stack | VictoriaMetrics + VictoriaLogs (`observability/`) with `VMServiceScrape` and `VMRule` CRDs, dot-notation logs (`kubernetes.container_name`) | **Replace** with `VMServiceScrape` for vLLM `/metrics`, `VMRule` for SLO alerts. |
| **Sealed Secrets for cluster bootstrap** | `EKSPodIdentity` (XR) for IAM, EPI prefix `xplane-*` (constitution-mandated) | **Use EPI XR** for vLLM → S3 model weights access. |
| Generic `helm install` flow | Flux GitOps with strict dependency hierarchy: Namespaces → CRDs → Crossplane → EPI → Security → Infra → Observability → Apps | **All HelmReleases via Flux**, never `helm install`. |
| Single-model deploy (Qwen3-8B only) | — | **Misses the brief.** You asked for routing across multiple models. |
| **ALB per service** for cost discussion | Already addressed: single Tailscale NLB shared across all services | Doc spends words on a non-problem. |
| **Spec-Driven Development** not mentioned | `/spec → /clarify → /validate → /create-pr` mandatory for new compositions and platform capabilities (`docs/specs/README.md`, constitution) | **The single biggest miss.** This work MUST be a phased spec. |
| **Crossplane composition pattern** not used | `App` XRD shows the canonical progressive-complexity pattern (image-only → SQL/S3/HPA/HTTPRoute via flags) — perfect template for `XInferenceService` | **Build a new KCL composition**, don't deploy raw HelmRelease per model. |

### 2.2 Technical claims that need updating for April 2026

The existing doc's tooling story is essentially **2024 vintage**. The actual SOTA in April 2026:

| Doc claim (vintage 2024) | Actual April 2026 state |
|---|---|
| "vLLM standalone, single replica, manual config" | **vLLM Production Stack** (vllm-project/production-stack) is the K8s reference: built-in router with **prefix-aware, KV-aware, session-aware routing**, **LMCache** integration, **KEDA autoscaler** baked into Helm chart since v0.1.9. |
| "Use Phi-4 Mini as draft model for speculative decoding alongside Qwen3-8B" | Speculative decoding still works, but the bigger win in 2026 is **prefix-cache-aware routing** (`llm-d` Endpoint Picker, ~57× P90 TTFT improvement vs round-robin per Red Hat 4/2026). |
| "DeepSeek-R1-Distill-7B for math/code" | Use **DeepSeek-R1-0528-Qwen3-8B distill** — surpasses base Qwen3-8B and Qwen3-32B on AIME 24 (per LM Studio model card 2026). |
| "Cost-based DoS protection via WAF" | **vLLM Semantic Router v0.1 "Iris"** (Jan 2026) ships with built-in plugins: jailbreak detection, PII filter, hallucination detection (HaluGate), semantic cache. Most "WAF for LLMs" concerns are now handled in-line by the router. |
| "Bottlerocket userData hack for image cache" | **Bottlerocket Accelerated AMI** ships with NVIDIA driver + device plugin pre-installed. EBS snapshot warmup is still the right pattern, just easier. |
| "OAuth2 Proxy + WAF" | For internal-only deployment (your answer): **Tailscale ACL** (`tag:k8s`) does identity-aware access; Semantic Router does L7 prompt filtering. WAF is unnecessary on a private endpoint. |

### 2.3 What the doc gets right (keep)

- Model fleet sizing for 8B-class on G6 / NVIDIA L4 24GB.
- FP8 quantization on L4 (native support, ~50% VRAM cut, negligible quality loss).
- TP=1 + multiple replicas > TP=4 single instance (better fault tolerance for spot).
- EBS snapshot warmup pattern (still valid, just easier with Accelerated AMI).
- Spot-first GPU NodePool with on-demand fallback.
- `g6.xlarge` as the workhorse instance.

---

## 3. Recommended architecture (April 2026, internal + showcase)

### 3.1 Stack picture

```
                            ┌────────────────────────────────────────────────┐
                            │ Tailscale tailnet (tag:k8s)                    │
                            │  └── *.priv.cloud.ogenki.io                    │
                            └─────────────────┬──────────────────────────────┘
                                              │ ExternalDNS → Route53 private
                                              ▼
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ Cilium Gateway API  (loadBalancerClass: tailscale, existing)             │
   │   parentRef: platform-tailscale-general                                  │
   └─────────────────┬─────────────────────────────────────┬──────────────────┘
                     │ HTTPRoute: chat.priv.ogenki.io      │ HTTPRoute: llm.priv.ogenki.io
                     ▼                                     ▼
            ┌────────────────┐                 ┌──────────────────────────────┐
            │ OpenWebUI      │ ─── OpenAI ───▶ │ vLLM Semantic Router (Iris)  │
            │ (App XR)       │                 │   ┌─ classifier (LoRA MoM)   │
            └────────────────┘                 │   ├─ jailbreak / PII filter  │
                                               │   ├─ semantic cache          │
                                               │   └─ cascade fallback        │
                                               └────────┬─────────────────────┘
                                                        │ tier-based dispatch
                            ┌───────────────────────────┼───────────────────────────┐
                            ▼ (small)                   ▼ (medium)                  ▼ (specialist)
                ┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────────┐
                │ Phi-4 Mini 3.8B     │    │ Qwen3-8B            │    │ DeepSeek-R1-Distill     │
                │ XInferenceService   │    │ XInferenceService   │    │ -Qwen3-8B (code/math)   │
                │ vLLM PS + LMCache   │    │ vLLM PS + LMCache   │    │ XInferenceService       │
                │ FP8 / 1× L4         │    │ FP8 / 1× L4         │    │ FP8 / 1× L4             │
                └─────────────────────┘    └─────────────────────┘    └─────────────────────────┘
                            │                          │                          │
                            └──────────────────────────┼──────────────────────────┘
                                                       ▼
                                       ┌──────────────────────────────┐
                                       │ LlamaGuard 3-1B (filter)     │
                                       │ XInferenceService (small)    │
                                       └──────────────────────────────┘

   Pod scale-to-zero: KEDA HTTP scaler (vLLM PS Helm v0.1.9+ ships with this)
   Node scale-to-zero: Karpenter NodePool gpu-l4 (consolidationPolicy: WhenEmptyOrUnderutilized)
   Model storage:     S3 (xplane-llm-models) + Bottlerocket EBS snapshot warmup
   Eval:              Promptfoo CronJob → results to VictoriaMetrics
   Observability:     VMServiceScrape on vLLM /metrics + VictoriaLogs unpack_json
   Identity / secrets: Tailscale ACL + ExternalSecret → AWS SM (HF_TOKEN, model API keys)
```

### 3.2 Component choices and why

| Layer | Choice | Why this beats alternatives |
|---|---|---|
| **Inference engine** | vLLM (latest) | Dominant 2026 runtime; native FP8 on L4; PagedAttention. |
| **Orchestration** | **vLLM Production Stack** (Helm) | Built-in router (round-robin / session / **prefix-aware** / **KV-aware** / disaggregated-prefill), LMCache, KEDA scaler. Lighter than KServe+llm-d+Knative for our scale. |
| **Routing intelligence** | **vLLM Semantic Router v0.1 "Iris"** (Jan 2026) | Multi-signal classifier (domain + keyword + embedding), MoM LoRA classifier (O(1)+O(n×ε) cost), built-in jailbreak/PII/hallucination/semantic-cache plugins, OpenAI Responses API. **Cascade fallback via plugin chain.** |
| **Pod scale-to-zero** | KEDA HTTP scaler (in vLLM PS chart) | Already integrated; `minReplicaCount: 0` + traffic keepalive trigger. |
| **Node scale-to-zero** | Karpenter (existing) — new `gpu-l4` NodePool | Consolidation policy + spot-first; no architectural change to repo. |
| **GPU AMI** | **Bottlerocket Accelerated AMI** | Driver + device plugin pre-installed. Dual-volume → EBS snapshot warmup (model weights baked in) → cold start <60s. |
| **Model storage** | S3 bucket via App XR `s3Bucket.enabled` + EPI for IAM | Reuse existing pattern; weights cached to local NVMe on cold start (RAID0 like `io-nodepool` precedent). |
| **Gateway** | Cilium GW API + Tailscale (existing) | Zero new components; HTTPRoute parentRef into `platform-tailscale-general`. |
| **Identity** | Tailscale ACL (`tag:k8s`) for users; ServiceAccount + Cilium NP for service-to-service | Internal-only — no need for OAuth2 Proxy. |
| **Secrets** | ExternalSecret → AWS SM (existing) | HF_TOKEN, model registry creds. |
| **Observability** | VMServiceScrape + VictoriaLogs + Grafana (existing) | New dashboards: `llm-platform-overview`, `llm-routing`, `llm-cost`. |
| **Guardrails** | (a) Semantic Router built-in plugins (jailbreak, PII), (b) **LlamaGuard 3-1B** as a small XInferenceService for content moderation pre/post | Two layers, cheap (1B model fits on shared GPU). |
| **Chat UI** | **OpenWebUI** via App composition behind Tailscale Gateway | Reuse existing `App` XRD; one HTTPRoute. |
| **Eval** | **Promptfoo** as CronJob, runs nightly against router endpoint | Lightweight (no DB), supports YAML eval suites, exports Prometheus metrics. |
| **Cost tracking** | vLLM PS exposes per-route/per-model token counters → VMServiceScrape → Grafana | No external billing system. Can later layer LiteLLM if multi-tenant. |

### 3.3 Why NOT KServe + llm-d (despite hype)

KServe `LLMInferenceService` (v0.16) + llm-d (CNCF Sandbox, March 2026) is **the SOTA architecture** and has **best-in-class prefix-cache-aware routing** (Endpoint Picker, ~57× P90 TTFT vs round-robin). But:

1. **Knative dependency** in KServe Serverless mode — adds a major new control plane to a repo that doesn't have it. RawDeployment mode avoids this but loses scale-to-zero.
2. **Overkill at 3-4 model fleet, internal-only scale.** llm-d's value is at multi-cluster, multi-tenant, fairness-prioritized serving.
3. **Stack depth** — Operator (KServe) + Operator (llm-d) + Inference Gateway (Envoy) on top of Cilium Envoy = double Envoy. Confusing.
4. **Migration path is clean.** vLLM PS routing keys + LMCache prefix pool are the same primitives llm-d uses. If you outgrow it, swap the router; the model pods stay.

**Decision:** vLLM Production Stack + Semantic Router v1; revisit KServe + llm-d when you cross 5+ model families or need multi-cluster federation.

---

## 4. Repo integration map

### 4.1 New files to create

| Path | Purpose |
|---|---|
| `infrastructure/base/karpenter-nodepools/gpu-l4-nodepool.yaml` | NodePool: g6 family, spot-first, GPU taints |
| `infrastructure/base/karpenter-nodepools/gpu-l4-ec2nodeclass.yaml` | EC2NodeClass: Bottlerocket Accelerated AMI, EBS snapshot warmup |
| `infrastructure/base/crossplane/configuration/kcl/inference-service/` | New KCL composition (full directory: `main.k`, `kcl.mod`, `inference-service-definition.yaml`, `composition.yaml`, `settings-example.yaml`, `main_test.k`, `examples/`, `README.md`) |
| `infrastructure/base/vllm-production-stack/` | HelmRelease for vLLM PS + KEDA + ServiceMonitor |
| `infrastructure/base/vllm-semantic-router/` | HelmRelease for `oci://ghcr.io/vllm-project/charts/semantic-router` |
| `apps/base/llm-platform/` | XInferenceService claims for Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen3-8B, LlamaGuard 3-1B |
| `apps/base/openwebui/` | App XR claim + HTTPRoute via `platform-tailscale-general` |
| `tooling/base/promptfoo/` | CronJob + ConfigMap with eval suite + ServiceMonitor |
| `observability/base/grafana-dashboards/llm-platform.yaml` | GrafanaDashboard CRD: routing, latency, GPU util, cost |
| `observability/base/victoria-metrics-k8s-stack/vmrules/llm-platform.yaml` | VMRule: queue depth SLO, cold-start, error rate, $/hour |
| `security/base/epis/llm-models-s3.yaml` | EPI XR for vLLM pods → S3 read |
| `docs/decisions/0003-vllm-production-stack-over-kserve.md` | ADR for the inference-stack decision (constitution requires ADRs for cross-cutting choices) |
| `docs/specs/NNN-self-hosted-llm-platform/` | Phased SDD spec (created by `/spec composition self-hosted-llm-platform`) |

### 4.2 Files to extend (carefully)

| Path | Change | Rationale |
|---|---|---|
| `infrastructure/base/crossplane/configuration/kcl/app/main.k` | Optional: add `gpu` field + `nodeSelector`/`tolerations` to enable GPU workloads via App XR | OpenWebUI doesn't need GPU; but exposing the field opens App XR to GPU experimentation later. **Defer to a separate spec.** |
| `infrastructure/base/gapi/platform-tailscale-general-gateway.yaml` | Add `apps`/`tooling` namespace allowance for new LLM HTTPRoutes (already permitted) | No change needed — already in `allowedRoutes.namespaces` |
| `flux/clusters/mycluster-0/` | Add Kustomization for `infrastructure/base/vllm-production-stack` etc. (Flux dependency: after Karpenter, after Crossplane EPI) | Standard pattern |

### 4.3 Reuse callouts (existing utilities to lean on)

| Use this | From | Instead of |
|---|---|---|
| `option("params").ocds` readiness pattern | `app/main.k:_observedDeployment...` | Custom readiness checks |
| `_setResourceRequirements()` lambda | `app/main.k` | Re-implementing limits/requests builder |
| EPI XR (`xplane-*` IAM scoping) | `eks-pod-identity/main.k` + `security/base/epis/` examples | IRSA (forbidden by ADR-0002) |
| External Secrets pattern | `security/base/cert-manager/openbao-approle-externalsecret.yaml` | Sealed Secrets / hardcoded creds |
| `VMServiceScrape` | `infrastructure/base/cilium/vmservicescrapes.yaml` | Prometheus ServiceMonitor (works but inconsistent) |
| `CiliumNetworkPolicy` (Zitadel pattern) | `security/base/zitadel/network-policy.yaml` | Generic NetworkPolicy |
| Cilium GW API HTTPRoute pattern | `docs/tailscale-gateway-api.md`, examples in `infrastructure/base/gapi/` | NGINX Ingress |
| `App` XR for OpenWebUI | `app/settings-example.yaml` | Hand-rolled Deployment+HPA+Service+HTTPRoute |
| CloudNativePG SQLInstance for Promptfoo result store | `cloudnativepg/main.k` | sqlite (loss on pod restart) |

---

## 5. SDD phasing — single phased spec, 7 phases

This is **one** spec (`docs/specs/NNN-self-hosted-llm-platform/`) with **7 phases** per `docs/specs/PHASED.md` (each independently shippable, each with falsifiable SC-XXX).

### Phase 1 — GPU Foundation
**Scope:** New Karpenter NodePool + EC2NodeClass + Bottlerocket Accelerated AMI verification.
**SC-1.1:** A test pod with `nvidia.com/gpu: 1` request schedules in <90s on a fresh node and returns `nvidia-smi` output.
**SC-1.2:** With no GPU pods running, the GPU node terminates within `consolidationDelay` (verified via `kubectl get nodes` + `karpenter` logs).
**SC-1.3:** EBS snapshot warmup reduces image-pull on second cold-start by >70% (timed with `kubectl get events`).
**Verification:** `kubectl run gpu-smoke --rm -it --image=nvidia/cuda:12.4.1-base-ubuntu22.04 --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists"}]}}' -- nvidia-smi`.

### Phase 2 — Inference stack install (vLLM PS + Semantic Router + KEDA)
**Scope:** HelmReleases via Flux for KEDA, vLLM Production Stack, vLLM Semantic Router. RBAC. CRDs in correct dependency order (CRDs phase).
**SC-2.1:** `helm list -A | grep -E 'keda|vllm-prod|semantic-router'` shows all three deployed and `STATUS: deployed`.
**SC-2.2:** `flux get hr -A` shows all three `Ready=True`.
**SC-2.3:** Default `vllm-prod-stack` Helm install completes with zero replicas (KEDA at minReplicaCount=0).

### Phase 3 — XInferenceService composition (KCL)
**Scope:** New KCL composition wrapping LLMInferenceService-equivalent: vLLM PS subresource refs + HPA/KEDA + HTTPRoute + VMServiceScrape + CiliumNetworkPolicy + EPI for S3.
**SC-3.1:** `./scripts/validate-kcl-compositions.sh` exits 0 (kcl fmt + kcl run + crossplane render + Polaris ≥ 85 + kube-linter).
**SC-3.2:** `main_test.k` covers: minimal claim renders ≥6 resources; full claim renders all observability; readiness reflects observed Deployment Available condition.
**SC-3.3:** `crossplane render` produces a valid `vllm-production-stack` Helm values fragment from a sample claim.
**Validation runs constitution checklist:** xplane-* prefix; no dict mutation; CiliumNetworkPolicy default-deny; EPI not IRSA; resource limits set.

### Phase 4 — Model storage & weights pipeline
**Scope:** S3 bucket `xplane-llm-models` (App XR `s3Bucket.enabled`), EPI scoped read-only, model preload Job pattern (download from HF on first-claim, cache to S3).
**SC-4.1:** A claim referencing `model.repository: Qwen/Qwen3-8B` causes a Job to pull weights to S3 within 10 min (one-time per model version).
**SC-4.2:** Pod cold-start with weights cached on EBS snapshot completes (`vLLM` ready) in <60s end-to-end.
**SC-4.3:** EPI grants exactly `s3:GetObject` on `xplane-llm-models/*` and nothing else (verified via `aws iam simulate-principal-policy`).

### Phase 5 — Model fleet + cascade routing
**Scope:** XInferenceService claims for the 4 models (Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen3-8B, LlamaGuard 3-1B). Semantic Router config with classifier and cascade fallback.
**SC-5.1:** OpenAI client (`POST /v1/chat/completions` with model `auto`) routes:
- "What's 2+2" → Phi-4 Mini (small/general tier)
- "Write a Python decorator that retries on TLS errors" → DeepSeek-R1-Distill (code tier)
- "Translate this haiku to Japanese" → Qwen3-8B (general)
**SC-5.2:** Routing decision adds <200ms p95 overhead measured via `vllm_semantic_router_latency_seconds` histogram.
**SC-5.3:** Jailbreak prompt set (10 known patterns) blocked by Semantic Router with 0 false negatives (logged in router decisions table).
**SC-5.4:** Per-model `vllm:gpu_cache_usage_perc` and `vllm:num_requests_waiting` scraped by VictoriaMetrics.

### Phase 6 — Chat UI (OpenWebUI)
**Scope:** App XR claim for OpenWebUI; ExternalSecret for OpenWebUI admin creds; HTTPRoute via Tailscale Gateway; CiliumNetworkPolicy allowing OpenWebUI → Semantic Router only.
**SC-6.1:** `https://chat.priv.cloud.ogenki.io` resolves and serves login page over Tailscale.
**SC-6.2:** A user can chat through the UI; streaming tokens appear; routing model is logged.
**SC-6.3:** Without Tailscale identity, request is dropped at Cilium Gateway (no public exposure).

### Phase 7 — Eval, guardrails, cost
**Scope:** Promptfoo CronJob + eval suite (50-200 prompts across categories) + Prometheus exporter; LlamaGuard 3-1B XInferenceService; Grafana dashboards (overview, routing decisions, cost); VMRules for SLO alerts.
**SC-7.1:** Nightly Promptfoo run produces a results JSON; `promptfoo_test_pass_rate` metric appears in VictoriaMetrics.
**SC-7.2:** A regression injection (intentionally mis-routing 20% of code prompts to Phi-4 Mini) drops `promptfoo_test_pass_rate{category="code"}` and triggers a `VMRule` alert.
**SC-7.3:** LlamaGuard pre-filter blocks the standard ToxiGen sample with ≥95% precision (measured by Promptfoo).
**SC-7.4:** `cost_dashboard` Grafana panel shows actual `$/hour` and `$ per 1M tokens` derived from instance pricing × utilization.

### Cross-cutting acceptance
- All compositions pass `/crossplane-validator`.
- All HelmReleases under Flux; no `kubectl apply` outside reconciliation.
- All workloads have CiliumNetworkPolicy (default-deny + explicit allow).
- All AWS access via EPI (xplane-* prefix); no IRSA.
- All metrics in VictoriaMetrics; all logs in VictoriaLogs (dot-notation).
- One ADR (0003) explaining the vLLM PS over KServe+llm-d choice.

---

## 6. Open decisions (must clarify before Phase 3)

These will become `clarifications.md` CL-N entries during the SDD `/clarify` step:

1. **Cascade vs hard route:** Should "model: auto" always cascade (tiny → mid → big based on confidence), or should we hard-route by classifier (no cascade)? Cascade is the more interesting engineering exercise but adds latency on miss. Iris supports both — pick.
2. **LlamaGuard placement:** Pre-filter only (block bad input), post-filter only (block bad output), or both? Both adds 2× LlamaGuard calls per request.
3. **Model preload trigger:** Auto on first claim (slow first request) vs explicit `kubectl apply -f preload-job.yaml` per model (manual but predictable)?
4. **Promptfoo eval cadence:** Nightly only, or on every Flux reconciliation of an XInferenceService? Latter catches drift faster but burns GPU.
5. **`App` XR GPU extension:** Extend the existing `App` composition with optional `gpu` field, or keep `App` strictly CPU and require `XInferenceService` for any GPU workload? (My recommendation: keep `App` CPU-only — `XInferenceService` is the contract for inference, `App` is the contract for stateless web/API.)
6. **`gpu-l4` NodePool capacity ceiling:** Hard cap at e.g. `nvidia.com/gpu: 4` to prevent runaway cost? Constitution mandates resource limits; should also apply to NodePools.

---

## 7. Verification commands (end-to-end happy path)

After all phases complete, the following must succeed in one go:

```bash
# 1. Cluster healthy
flux get all -A | grep -v 'True' && echo "FAIL: not all Flux resources Ready" || echo "OK"

# 2. GPU NodePool functional
kubectl run gpu-smoke --rm -it --restart=Never \
  --image=nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"nodeSelector":{"karpenter.sh/nodepool":"gpu-l4"},"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists"}],"containers":[{"name":"smoke","image":"nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"]}]}}'

# 3. XInferenceService claims Ready
kubectl get xinferenceservice -A
# Expect: Synced=True, Ready=True for phi4-mini, qwen3-8b, deepseek-r1-distill, llamaguard3-1b

# 4. Routing E2E (cascade + classification)
curl -fsS https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"auto","messages":[{"role":"user","content":"Write a Rust function to parse CIDR ranges"}]}' \
  | jq '.model'
# Expect: "deepseek-r1-distill-qwen3-8b" (code-routing)

# 5. Semantic Router latency SLO
curl -s https://llm.priv.cloud.ogenki.io/metrics \
  | grep vllm_semantic_router_latency_seconds_bucket \
  | awk '/le="0.2"/ {print}'
# Expect: bucket count >= 95% of total

# 6. Scale-to-zero verification
sleep 600 && kubectl get pods -n llm-platform -l app=phi4-mini
# Expect: 0 pods (KEDA scaled to zero after idle)
kubectl get nodes -l karpenter.sh/nodepool=gpu-l4
# Expect: 0 nodes (Karpenter consolidated)

# 7. Cold-start
time curl -fsS https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"phi4-mini","messages":[{"role":"user","content":"hi"}]}'
# Expect: <90s end-to-end (Karpenter node + vLLM warm + first token)

# 8. Promptfoo eval baseline
kubectl create job promptfoo-manual --from=cronjob/promptfoo -n tooling
kubectl wait --for=condition=complete job/promptfoo-manual -n tooling --timeout=600s
kubectl logs -n tooling job/promptfoo-manual | tail -20
# Expect: pass rate >= baseline, JSON written to S3

# 9. Constitution compliance
./scripts/validate-kcl-compositions.sh   # exit 0
./scripts/validate-spec.sh docs/specs/NNN-self-hosted-llm-platform/   # 0 errors
```

---

## 8. Out of scope (explicit defer list)

So you can later say "this was intentional, not forgotten":

- **Public Internet exposure** of any LLM endpoint (you chose internal-only).
- **Multi-tenancy / per-user quotas / billing** (LiteLLM proxy can be layered later).
- **Fine-tuning / LoRA hot-swap** (cache-aware LoRA routing exists in llm-d v0.5; revisit if needed).
- **RAG pipeline** (vector DB, embedding service, retrieval augmentation) — separate spec.
- **Multi-cluster federation** — current repo is single cluster.
- **Tensor parallelism / multi-GPU per replica** — TP=1 is correct at 8B scale; TP>1 only when you go to 70B+.
- **NVIDIA Inferentia** (`inf2.xlarge`) — Trainium/Inferentia toolchain is a different model serving path. Cheaper but more lock-in. Leave as future ADR.
- **GraphQL / non-OpenAI API surface** — Semantic Router exposes OpenAI; that's the ecosystem standard.
- **Model fine-tuning infrastructure** — this plan is inference-only.

---

## 9. Why this plan beats the original doc

| Dimension | Original doc | This plan |
|---|---|---|
| **Repo fit** | Generic — would replace existing stacks (NGINX, OAuth2, Sealed Secrets) | Reuses **all** existing platform primitives; only adds what's genuinely new |
| **Routing** | None (single model) | **vLLM Semantic Router Iris** — multi-signal classifier + cascade + jailbreak/PII/cache plugins |
| **Composition** | Raw HelmReleases per service | **`XInferenceService` KCL composition** — progressive complexity like existing `App` |
| **SDD compliance** | Bypasses entirely | One phased spec, 7 phases with falsifiable SC-XXX |
| **Constitutional compliance** | Multiple violations (no CiliumNetworkPolicy, no EPI, no KCL) | Audited per checklist; ADR-0003 added |
| **Scale-to-zero** | Mentions Karpenter only (node-level) | KEDA HTTP scaler + Karpenter consolidation = full pod+node scale-to-zero |
| **Eval & quality** | Not addressed | Promptfoo CronJob + VMRule alerts on regression |
| **Guardrails** | WAF (wrong layer for prompts) | Semantic Router plugins + LlamaGuard 3-1B inline |
| **April 2026 SOTA** | Vintage 2024 tooling | vLLM PS, Semantic Router Iris, Bottlerocket Accelerated AMI, KEDA HTTP scale-to-zero |
| **Cost story** | Spot pricing table, no observability | VictoriaMetrics-derived `$/hour` + `$/1M tokens` Grafana panel |

---

## 10. Suggested first command

```bash
./scripts/sdd/create-spec.sh composition self-hosted-llm-platform
```

This creates `docs/specs/NNN-self-hosted-llm-platform/` with the 3 artifacts and a linked GitHub issue. Then `/clarify` runs against the 6 open decisions in §6, `/validate` enforces the constitution, `/create-pr` ships Phase 1.
