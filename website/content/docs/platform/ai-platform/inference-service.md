---
title: The InferenceService claim
weight: 20
description: One model, one YAML file — the complete claim, what it renders, and every field it accepts.
lastVerified: 2026-08-30
---

A model on this platform is one file. No Deployment, no Service, no HPA, no
route, no PVC — an `InferenceService` claim, and the Crossplane composition
renders the rest. The four models running today each live in a single
manifest under `apps/base/ai/llm/`.

## A complete claim

`apps/base/ai/llm/qwen-coder-fim.yaml` is the most instructive of the four,
because almost every field in it is a decision rather than a default. Its
comments are condensed from the file — they are the reasoning, and stripping
them would leave the least interesting half:

```yaml
# FIM (Fill-in-the-Middle) tab-completion model — the Continue VSCode
# extension's autocomplete profile, plus any other editor that wants
# inline keystroke-time suggestions.
#
# Why this exact model:
# - **Base**, not Instruct. The FIM tokens are trained into the base
#   model; the Instruct fine-tune dilutes them.
# - 1.5B params at fp8 ~= 4Gi VRAM, fits on an L4 alongside the
#   always-warm LlamaGuard guardrail.
# - Apache 2.0.
# - Same Qwen tokenizer family as the other two models, so the KV cache
#   stays warm across tab-complete + chat traffic.
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-qwen-coder-fim
  namespace: llm
spec:
  model:
    repository: Qwen/Qwen2.5-Coder-1.5B
    # Pinned commit SHA, not a tag: a HuggingFace repo is mutable.
    revision: df3ce67c0e24480f20468b6ef2894622d69eb73b
    quantization: fp8
    # FIM context windows are short — a single file's surrounding
    # context, not the whole repo. 8k saves VRAM for KV cache.
    contextWindow: 8192
    maxNumSeqs: 64
    preload:
      enabled: true
  gpu:
    count: 1
    minVRAM: 8Gi
  routing:
    tier: small
    specialty: code-fim
  scaling:
    # ALWAYS WARM. Tab-complete must answer in <200ms p95, and a cold
    # start (model load + cudagraph compile) is 30-90s — that would
    # break the UX on the first keystroke after a quiet minute.
    minReplicas: 1
    maxReplicas: 1
  cache:
    # Critical for FIM: every keystroke shares the same prefix (the file
    # up to the cursor), so prefix cache turns each subsequent keystroke
    # into an O(1) lookup of the cached KV.
    prefixCache:
      enabled: true
  envFromSecrets:
    - hf-token
  observability:
    metrics:
      interval: "30s"
```

{{< callout type="warning" >}}
**One constraint this claim cannot express.** The composition does not expose
pod-template annotations, so this pod cannot be tagged
`karpenter.sh/do-not-disrupt: "true"` directly. The defence lives on the
NodePool instead: `gpu-l4` sets `consolidationPolicy: WhenEmpty` rather than
the default `WhenEmptyOrUnderutilized`, so a node hosting an always-warm pod
is never consolidated out from under it. AWS spot reclaim can still cause a
30–90s multi-AZ PVC re-attach — acceptable for solo work, not for a team tier.
{{< /callout >}}

## What one claim renders

![One InferenceService claim expanding into a vLLM Deployment on the GPU NodePool, its Service and AIServiceBackend, the Envoy AI Gateway route that maps the model name onto it, the KEDA ScaledObject that scales it on vLLM saturation metrics, and the S3-backed PVC the weights are read from](/images/diagrams/llm-platform-2.svg)

A vLLM Deployment scheduled onto the `gpu-l4` NodePool, its Service, a
`ScaledObject`, the PVC that mounts the shared weights filesystem, a preload
Job that fetches the weights on first use, a `CiliumNetworkPolicy` per
workload, and — when `gateway.enabled` is set — the `AIGatewayRoute`,
`AIServiceBackend` and `Backend` that make the model addressable by name.

## Field reference

Against the `InferenceService` XRD shipped in the Crossplane Configuration
package pinned at `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`.

### `spec.model` — required

| Field | Type | Notes |
|---|---|---|
| `repository` | string, required | HuggingFace repo, e.g. `Qwen/Qwen3-8B` |
| `revision` | string | Commit SHA. Every claim here pins one — a HuggingFace repository is mutable, so a tag is not a pin |
| `quantization` | string | `fp8` on the three Qwen models, `fp16` on LlamaGuard |
| `contextWindow` | int | Tokens. 32768 for chat and code, 8192 for FIM and the guardrail |
| `maxNumSeqs` | int | vLLM's batch cap — and the denominator of the batch-saturation autoscaling trigger, so it is a scaling input, not only a memory one |
| `toolCallParser` | string | `hermes` on both Qwen instruct models; absent for FIM and the guardrail, neither of which does tool calling |
| `preload.enabled` | bool | Runs a Job that pulls the weights onto the shared filesystem before the serving pod starts |

### `spec.gpu`

| Field | Type | Notes |
|---|---|---|
| `count` | int | Always `1` here — the `gpu-l4` NodePool excludes multi-GPU SKUs on purpose |
| `minVRAM` | quantity | `8Gi` for the 1.5B models, `16Gi` for the 7B/8B ones |

### `spec.scaling`

| Field | Type | Notes |
|---|---|---|
| `minReplicas` | int | Defaults to 1. Never 0 — see [Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/autoscaling-and-gpu.md" >}}) for the deadlock that rules out scale-to-zero |
| `maxReplicas` | int | 1 for FIM (always exactly one), 2 for the chat models, 3 for the guardrail |

### `spec.cache`

| Field | Type | Notes |
|---|---|---|
| `prefixCache.enabled` | bool | Shared-prefix KV reuse. Decisive for FIM, useful everywhere |
| `kvOffload.enabled` / `.sizeGB` | bool / int | Spills KV cache to host memory — `16` GB on both 7B/8B models |

### `spec.routing`

| Field | Type | Notes |
|---|---|---|
| `tier` | string | `small` / `medium` — capability class |
| `specialty` | string | `code`, `code-fim`, `general` — what the Semantic Router matches on |

### `spec.loraAdapters[]` and `spec.gateway`

Only `xplane-qwen-coder` uses these today.

| Field | Type | Notes |
|---|---|---|
| `loraAdapters[].name` | string | Becomes an addressable model name in its own right |
| `loraAdapters[].repository` / `.revision` | string | Same pinning rule as the base model |
| `gateway.enabled` | bool | Composition-owned routing. When false, the route must be hand-written |
| `gateway.canaries[].adapter` | string | An adapter name **verbatim** — it is matched, not derived |
| `gateway.canaries[].weightPercent` | int | 10% of `xplane-qwen-coder` traffic goes to the SQL-DPO adapter |

### `spec.envFromSecrets[]` and `spec.observability`

| Field | Type | Notes |
|---|---|---|
| `envFromSecrets` | []string | `hf-token`, delivered by External Secrets from AWS Secrets Manager — never in Git |
| `observability.metrics.interval` | duration | `30s` on all four; drives the `VMServiceScrape` the composition renders |

## The model fleet

Four claims, read from the manifests:

| Model | Repository | Quant | Context | `maxNumSeqs` | min/max | Gateway |
|---|---|---|---|---|---|---|
| `xplane-qwen-coder` | `Qwen/Qwen2.5-Coder-7B-Instruct` | fp8 | 32k | 32 | 1 / 2 | composition-owned, 10% canary onto `xplane-qwen-coder-sql-dpo` |
| `xplane-qwen3-8b` | `Qwen/Qwen3-8B` | fp8 | 32k | 32 | 1 / 2 | hand-written route |
| `xplane-qwen-coder-fim` | `Qwen/Qwen2.5-Coder-1.5B` | fp8 | 8k | 64 | 1 / 1 | hand-written route |
| `xplane-llamaguard3-1b` | `meta-llama/Llama-Guard-3-1B` | fp16 | 8k | 64 | 1 / 3 | hand-written route |

Every model defaults to `minReplicas: 1` — there is no scale-to-zero — and the
`gpu-l4` NodePool caps the fleet at `nvidia.com/gpu: "4"`; see
[Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/autoscaling-and-gpu.md" >}})
for the cost floor that implies.

## Adding a model

Copy the closest existing claim, change `model.repository` and `revision`, set
`gpu.minVRAM` for the parameter count and quantization, pick a `routing.tier`
and `specialty`, and open a PR — the same review and merge gates as any other
manifest, described in [Validation]({{< relref "/docs/platform/gitops/validation.md" >}}).

Two things to check before merging: the fleet fits within the four-GPU cap
with the new model at `minReplicas`, and — if the model should be reachable
through `model: MoM` rather than only by name — that a Semantic Router
decision rule targets it. See
[Gateway & routing]({{< relref "/docs/platform/ai-platform/gateway-and-routing.md" >}});
two of the four models today are reachable only by naming them explicitly.
