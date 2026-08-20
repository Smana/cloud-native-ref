---
title: AI Platform
weight: 50
description: An OpenAI-compatible vLLM serving platform behind Envoy AI Gateway, scaled by KEDA on vLLM saturation signals — off by default until two independent gates are both released.
lastVerified: 2026-08-20
---

An OpenAI-compatible inference platform on EKS: vLLM on L4 spot GPUs, fronted by
Envoy AI Gateway, scaled by KEDA on vLLM saturation signals, and declared as a
single Crossplane `InferenceService` claim per model.

{{< callout type="warning" >}}
**This platform is off by default.** Two independent gates must both be
released before anything LLM-related exists on the cluster — see
[Turning it on](#turning-it-on) below. A plain `terramate script run deploy`
and a plain Flux reconciliation both leave the cluster LLM-free.
{{< /callout >}}

## Turning it on

The two gates are deliberately independent, so that neither one accidentally
brings the other along:

```bash
# Gate 1 — AWS side (S3 Files filesystem + IAM). Terramate stack tagged
# `opt-in`; skipped unless TM_LLM_PLATFORM_ENABLED=true (verified in
# opentofu/llm-platform/workflows.tm.hcl — unset or != "true" echoes [skip]
# and exits 0).
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/llm-platform script run deploy

# Gate 2 — Kubernetes side. The umbrella Flux Kustomization ships suspended
# (spec.suspend: true, clusters/mycluster-0/llm-platform.yaml).
flux resume kustomization llm-platform -n flux-system
```

The umbrella aggregates **8** child Flux Kustomizations under
`clusters/mycluster-0-llm-platform/`:

| Child | Renders | Path |
|---|---|---|
| `vllm-semantic-router` | Prompt-classification router (`MoM` virtual model) | `infrastructure/base/vllm-semantic-router` |
| `runtimeclass-nvidia` | `RuntimeClass nvidia` | `infrastructure/base/runtimeclass-nvidia` |
| `llm-platform-gpu-nodepools` | Karpenter `gpu-l4` NodePool + EC2NodeClass | `infrastructure/base/karpenter-nodepools-gpu` |
| `envoy-gateway` | Envoy Gateway controller | `infrastructure/base/envoy-gateway` |
| `envoy-ai-gateway` | Envoy AI Gateway + the Semantic Router `EnvoyPatchPolicy` | `infrastructure/base/envoy-ai-gateway` |
| `llm-platform-apps` | The `InferenceService` claims + OpenWebUI | `apps/base/ai/llm` |
| `llm-platform-security-epi` | The preload Job's EKS Pod Identity | `security/base/epis-llm` |
| `llm-platform-promptfoo` | Nightly agent-eval CronJob | `tooling/base/promptfoo` |

That directory is a **sibling** of `clusters/mycluster-0/`, not a child, on
purpose: `flux-system` syncs `clusters/mycluster-0/` recursively, so a nested
path would be auto-discovered and applied — bypassing the suspend gate
entirely.

## At a glance

| | |
|---|---|
| **Engine** | vLLM, one Deployment per model, port 8000 |
| **Gateway** | Envoy Gateway + Envoy AI Gateway `1.0.0` |
| **Routing** | `AIGatewayRoute`, keyed on the `x-ai-eg-model` header |
| **Prompt routing** | vLLM Semantic Router, as a gRPC `ext_proc` filter — only acts on `model: MoM` |
| **Autoscaling** | KEDA, three vLLM saturation triggers OR-combined, `min=1` (always warm) |
| **Weights** | Amazon S3 Files (POSIX over S3), RWX PVC shared by a preload Job and the serving pod |
| **GPUs** | Karpenter `gpu-l4` NodePool — single-GPU `g6` spot instances, Bottlerocket NVIDIA AMI, capped at 4 GPUs total |
| **Composition** | `crossplane-inference-service` KCL module `0.9.0`, pinned inside `crossplane-configuration-aws:v0.1.0` |

## Request path

A request crosses two gateways and up to two filters before it reaches a GPU.

![One OpenAI-compatible request from a laptop to a GPU: the client reaches the Cilium Gateway over Tailscale, the Envoy AI Gateway authenticates it with an API key from AWS Secrets Manager, strips the Authorization header, and routes it through the semantic-router and rate-limit filters onto the vLLM Service backing the requested model](/images/diagrams/llm-platform-1.svg)

**Ingress.** External clients arrive over Tailscale at the Cilium Gateway
`platform-tailscale-general` and are forwarded to the Envoy AI Gateway data
plane Service. In-cluster clients (OpenWebUI, the nightly Promptfoo eval)
address that Service directly.

**Authentication.** A `SecurityPolicy` (`apiKeyAuth`) targets the Gateway, so
every route inherits it. Keys come from AWS Secrets Manager via External
Secrets; the gateway strips the `Authorization` header before forwarding
upstream, so vLLM never sees it.

**Prompt classification (`ext_proc`, filter index 0).** The Semantic Router
is wired in as an Envoy `ext_proc` gRPC filter, inserted **ahead of** the AI
Gateway's own extproc by an `EnvoyPatchPolicy` (a raw xDS JSONPatch — an
`EnvoyExtensionPolicy` can only append filters, and ordering here is not
optional). It only rewrites `body.model` when the client sent `model: MoM`
(or the literal `auto`); an explicit `xplane-*` model name passes through
untouched.

**Routing.** The AI Gateway extproc derives `x-ai-eg-model` from the
(possibly rewritten) request body and emits `gen_ai_*` telemetry. An
`AIGatewayRoute` matches that header and forwards through an
`AIServiceBackend` → `Backend` → the model's Service on port 8000. Today only
`xplane-qwen-coder` has its gateway objects composition-owned
(`spec.gateway.enabled: true`); the other three claims still route through a
hand-written `apps/base/ai/llm/ai-gateway-routes/route.yaml`.

## Semantic routing — `model: MoM`

Sending `model: MoM` lets the Semantic Router pick a model from the prompt.
Its decision list, highest priority first
(`infrastructure/base/vllm-semantic-router/helmrelease.yaml`):

| Priority | Decision | Target |
|---|---|---|
| 110 | code + reasoning | `xplane-qwen-coder` (`use_reasoning: true`) |
| 100 | code | `xplane-qwen-coder` |
| 90 | reasoning (math / physics) | `xplane-qwen3-8b` (`use_reasoning: true`) |
| 80 | multilingual | `xplane-qwen3-8b` |
| 50 | general (the default) | `xplane-qwen3-8b` |

Naming a model explicitly skips classification (roughly 250–300 ms) entirely
— see [Coding Clients]({{< relref "/docs/platform/ai-platform/coding-clients.md" >}})
for which client pins which model.

{{< callout type="warning" >}}
`xplane-llamaguard3-1b` and the two LoRA adapters on `xplane-qwen-coder`
appear in **no** decision rule above — they hold serving capacity but are
reachable only by naming them directly. The router's own in-pod `prompt_guard`
classifier blocks jailbreak attempts; it is not a routing decision, and there
is no automatic guardrail dispatch.
{{< /callout >}}

![What a single InferenceService claim renders: a vLLM Deployment on the GPU NodePool, its Service and AIServiceBackend, the Envoy AI Gateway route that sends the model's name to it, and the KEDA ScaledObject that scales it — plus the S3-backed weights the pod pulls on start](/images/diagrams/llm-platform-2.svg)

## The model fleet

Four claims under `apps/base/ai/llm/`, verified against the manifests:

| Model | Repository | Quant | Context | `maxNumSeqs` | min/max replicas | Gateway |
|---|---|---|---|---|---|---|
| `xplane-qwen-coder` | `Qwen/Qwen2.5-Coder-7B-Instruct` | fp8 | 32k | 32 | 1 / 2 | composition-owned, 10% canary onto `xplane-qwen-coder-sql-dpo` |
| `xplane-qwen3-8b` | `Qwen/Qwen3-8B` | fp8 | 32k | 32 | 1 / 2 | hand-written route |
| `xplane-qwen-coder-fim` | `Qwen/Qwen2.5-Coder-1.5B` | fp8 | 8k | 64 | 1 / 1 | hand-written route |
| `xplane-llamaguard3-1b` | `meta-llama/Llama-Guard-3-1B` | fp16 | 8k | 64 | 1 / 3 | hand-written route |

Every model defaults to `minReplicas: 1` — there is no scale-to-zero — and
the `gpu-l4` NodePool caps the fleet at `nvidia.com/gpu: "4"`, so those four
`min=1` models are a hard cost ceiling, not a soft one.

## Autoscaling

One KEDA `ScaledObject` per model, always rendered, with **three**
Prometheus triggers OR-combined against VictoriaMetrics — any one at or
above threshold drives a scale-up. Verified directly against the pinned KCL
module (`apis/inferenceservice/kcl/main.k` in `Smana/crossplane-configuration`
at the pinned tag):

| # | Signal | Query | Default threshold |
|---|---|---|---|
| 1 | batch saturation | `max(vllm:num_requests_running{model_name="X"}) / scalar(vector(<maxNumSeqs>))` | `0.7` |
| 2 | KV-cache pressure | `max(vllm:kv_cache_usage_perc{model_name="X"})` | `0.6` |
| 3 | queue depth | `max(vllm:num_requests_waiting{model_name="X"})` | `8` |

All three are **leading** signals — they fire before the batch saturates,
before the cache evicts, before the queue builds — and `max()` rather than
an average is deliberate: it tracks the hottest replica instead of a fleet
mean that would hide it. Defaults: `pollingInterval: 15s`,
`cooldownPeriod: 300s`.

The **legacy KEDA HTTP add-on is no longer used.** It put a proxy in the
data path and scaled on a lagging request-count trigger; the module's own
comments record the switch away from it. The AI Gateway routes directly to
each vLLM Service — there is no scaling proxy in front of the fleet.

{{< callout type="warning" >}}
A fourth, opt-in trigger on the Gateway API Inference Extension's
InferencePool saturation gauge is specified
(`docs/specs/done/2026-Q3/011-inferencepool-saturation-keda/spec.md`), but
it could not be verified: the pinned KCL module renders only the three
triggers above, and that spec's own task and review checklists are almost
entirely unchecked. Treat it as **not shipped** despite living under the
`done` archive, and re-verify before citing it as delivered.
{{< /callout >}}

![The three KEDA triggers OR-combined against VictoriaMetrics, the two metric families vLLM exposes, and the dashboards and alerts they feed](/images/diagrams/llm-platform-3.svg)

## Security posture

- **Zero trust by default.** Every workload carries a default-deny
  `CiliumNetworkPolicy`. The serving pod's egress is kube-dns only; only the
  bounded preload Job is granted `world:443`, because it is short-lived and
  the serving pod cannot reach HuggingFace even in principle.
- **No credentials in Git.** API keys and the HuggingFace token come from AWS
  Secrets Manager through External Secrets — see
  [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}).
- **No IAM on the serving pod.** Weights arrive over the CSI mount, so the
  serving ServiceAccount carries no role. Only the preload Job carries an
  EKS Pod Identity.
- **Private ingress only.** Reachable exclusively from the tailnet — see
  [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}})
  for how the Tailscale Gateway model works.

## GPU foundation and storage

**GPUs.** Karpenter NodePool `gpu-l4`: single-GPU `g6` instances only (the
NodePool explicitly excludes multi-GPU SKUs such as `g6.12xlarge` and
`g6.48xlarge`, so one claim can never consume the whole GPU cap), spot-first,
Bottlerocket NVIDIA AMI, capped at `nvidia.com/gpu: "4"`. There is no NVIDIA
device-plugin DaemonSet — the Bottlerocket NVIDIA variant advertises
`nvidia.com/gpu` through the kubelet natively.

**Weights.** An Amazon S3 Files filesystem (POSIX over S3) is mounted RWX at
`/models` by both the preload Job and the serving pod, each with its own
`subPath`. See [ADR-0004]({{< relref "/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md" >}})
for why this replaced an init-container sync, and
[ADR-0003]({{< relref "/docs/decisions/0003-vllm-production-stack-over-kserve.md" >}})
for why vLLM Production Stack was chosen over KServe + llm-d.

## Known gaps

- **`xplane-llamaguard3-1b` holds a GPU and serves no automatic traffic** —
  it runs at `min=1` but appears in no Semantic Router decision rule.
- **Gateway routing is half-migrated** — only `xplane-qwen-coder` is
  composition-owned; the other three claims still route through the
  hand-written `apps/base/ai/llm/ai-gateway-routes/route.yaml`.
- **The Gateway API Inference Extension's endpoint picker is implemented but
  enabled on zero claims.** It is mutually exclusive with LoRA canaries, and
  the only gateway-enabled claim uses a canary — see the
  [roadmap]({{< relref "/docs/platform/ai-platform/roadmap.md" >}}) for what
  turning it on would take.
- **No distributed tracing.** OTLP export from the AI Gateway extproc is
  written but not enabled, pending verification against VictoriaTraces.

{{< cards >}}
  {{< card link="/docs/platform/ai-platform/coding-clients/" title="Coding Clients" icon="terminal" subtitle="Connecting OpenCode, Continue, and OpenWebUI to the gateway — authentication, model IDs, and troubleshooting." >}}
  {{< card link="/docs/platform/ai-platform/roadmap/" title="Roadmap" icon="map" subtitle="What's still open on the upgrade path — bigger models, multi-replica serving, and per-tenant cost attribution." >}}
{{< /cards >}}
