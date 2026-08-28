---
title: AI Platform
weight: 50
description: An OpenAI-compatible vLLM serving platform behind Envoy AI Gateway, declared one model per Crossplane claim — off by default until two independent gates are both released.
lastVerified: 2026-08-27
---

An OpenAI-compatible inference platform on EKS: vLLM on L4 spot GPUs, fronted
by Envoy AI Gateway, scaled by KEDA on vLLM saturation signals, and declared
as a single Crossplane
[`InferenceService` claim]({{< relref "/docs/platform/ai-platform/inference-service.md" >}})
per model.

{{< callout type="warning" >}}
**This platform is off by default.** Two independent gates must both be
released before anything LLM-related exists on the cluster — see
[Turning it on](#turning-it-on). A plain `terramate script run deploy` and a
plain Flux reconciliation both leave the cluster LLM-free.
{{< /callout >}}

## At a glance

| | |
|---|---|
| **Engine** | vLLM, one Deployment per model, port 8000 |
| **Gateway** | Envoy Gateway + Envoy AI Gateway `1.1.0` |
| **Routing** | `AIGatewayRoute`, keyed on the `x-ai-eg-model` header |
| **Prompt routing** | vLLM Semantic Router, as a gRPC `ext_proc` filter — only acts on `model: MoM` |
| **Autoscaling** | KEDA, three vLLM saturation triggers OR-combined, `min=1` (always warm) |
| **Weights** | Amazon S3 Files (POSIX over S3), RWX PVC shared by a preload Job and the serving pod |
| **GPUs** | Karpenter `gpu-l4` NodePool — single-GPU `g6` spot instances, Bottlerocket NVIDIA AMI, capped at 4 GPUs |
| **Composition** | `crossplane-inference-service` KCL module `0.9.0`, pinned inside `crossplane-configuration-aws:v0.4.5` |

## Why self-host at all

A hosted API is cheaper, faster to adopt, and better at the frontier. This
platform exists for the things a hosted API cannot give you:

- **Prompts never leave the tailnet.** Every request path here is private —
  there is no public endpoint, and no third party sees the code being
  completed. That is the whole reason the coding fleet exists.
- **The model is pinned to a commit.** `model.revision` is a HuggingFace
  commit SHA, so the model behind an endpoint cannot change under you. A
  hosted endpoint's weights move when the provider decides.
- **Latency is a scheduling problem, not a queue you do not control.**
  Tab-completion needs sub-200 ms; that is achievable when the replica is
  yours and always warm, and not negotiable with a shared API.
- **It is a real workload for the platform to carry.** GPUs, spot reclaim,
  saturation-based autoscaling, a shared RWX filesystem and an
  ext_proc-filtered gateway exercise parts of this platform that a stateless
  web app never touches.

And the honest side of the ledger: there is **no scale-to-zero** — see
[Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/autoscaling-and-gpu.md" >}})
for the four-GPU cost floor that implies, and why it is a deadlock rather
than a missing feature.

## Turning it on

The two gates are deliberately independent, so neither one accidentally
brings the other along:

```bash
# Gate 1 — AWS side (S3 Files filesystem + IAM). Terramate stack tagged
# `opt-in`; skipped unless TM_LLM_PLATFORM_ENABLED=true (verified in
# opentofu/aws/llm-platform/workflows.tm.hcl — unset or != "true" echoes [skip]
# and exits 0).
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/aws/llm-platform script run deploy

# Gate 2 — Kubernetes side. The umbrella Flux Kustomization ships suspended
# (spec.suspend: true, clusters/aws-0/llm-platform.yaml).
flux resume kustomization llm-platform -n flux-system
```

The umbrella aggregates **8** child Flux Kustomizations under
`clusters/aws-0-llm-platform/`:

| Child | Renders | Path |
|---|---|---|
| `vllm-semantic-router` | Prompt-classification router (`MoM` virtual model) | `infrastructure/base/vllm-semantic-router` |
| `runtimeclass-nvidia` | `RuntimeClass nvidia` | `infrastructure/base/runtimeclass-nvidia` |
| `llm-platform-gpu-nodepools` | Karpenter `gpu-l4` NodePool + EC2NodeClass | `infrastructure/base/karpenter-nodepools-gpu` |
| `envoy-gateway` | Envoy Gateway controller | `infrastructure/base/envoy-gateway` |
| `envoy-ai-gateway` | Envoy AI Gateway + the Semantic Router `EnvoyPatchPolicy` | `infrastructure/base/envoy-ai-gateway` |
| `llm-platform-apps` | The `InferenceService` claims + OpenWebUI | `apps/llm` |
| `llm-platform-security-epi` | The preload Job's EKS Pod Identity | `security/base/epis-llm` |
| `llm-platform-promptfoo` | Nightly agent-eval CronJob | `tooling/base/promptfoo` |

That directory is a **sibling** of `clusters/aws-0/`, not a child, on
purpose: `flux-system` syncs `clusters/aws-0/` recursively, so a nested
path would be auto-discovered and applied — bypassing the suspend gate
entirely.

### On `gcp-0`

`gcp-0` has **one gate, not two**: the weights bucket is a Crossplane claim
rather than an OpenTofu stack, so there is no `TM_LLM_PLATFORM_ENABLED` —
the only gate is the umbrella Kustomization `clusters/gcp-0/llm-platform.yaml`
(`spec.suspend: true`). Weights are served from a GCS bucket over the Cloud
Storage FUSE CSI driver instead of an S3 Files POSIX mount — see
[ADR-0021]({{< relref "/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md" >}})
for why, including what it gives up. **Do not resume that umbrella yet**:
serving pods have no per-claim GCP read identity (the `InferenceService`
composition renders none for GCP), so vLLM pods cannot read the weights
bucket — the gap is recorded in `clusters/gcp-0-llm-platform/README.md` and
must be closed first.

## Security posture

- **Zero trust by default.** Every workload carries a default-deny
  `CiliumNetworkPolicy`. The serving pod's egress is kube-dns only; only the
  bounded preload Job is granted `world:443`, because it is short-lived and
  the serving pod cannot reach HuggingFace even in principle.
- **No credentials in Git.** API keys and the HuggingFace token come from AWS
  Secrets Manager through External Secrets — see
  [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}).
- **Read-only IAM on the serving pod.** Each claim's serving
  ServiceAccount carries a per-claim EKS Pod Identity scoped to *read* its
  own weights prefix, rendered by the composition; only the shared preload
  Job's identity can write to the bucket.
- **Private ingress only.** Reachable exclusively from the tailnet — see
  [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}}).

## Known gaps

- **`xplane-llamaguard3-1b` holds a GPU and serves no automatic traffic** —
  it runs at `min=1` but appears in no Semantic Router decision rule.
- **Gateway routing is half-migrated** — only `xplane-qwen-coder` is
  composition-owned; the other three claims still route through the
  hand-written `apps/base/ai/llm/ai-gateway-routes/route.yaml`.
- **The Gateway API Inference Extension's endpoint picker is implemented but
  enabled on zero claims.** It is mutually exclusive with LoRA canaries, and
  the only gateway-enabled claim uses a canary.
- **No distributed tracing.** OTLP export from the AI Gateway extproc is
  written but not enabled, pending verification against VictoriaTraces.

{{< cards >}}
  {{< card link="/docs/platform/ai-platform/inference-service/" title="The InferenceService claim" icon="document-text" subtitle="One model, one YAML file — a complete claim with its reasoning intact, what it renders, and every field it accepts." >}}
  {{< card link="/docs/platform/ai-platform/gateway-and-routing/" title="Gateway & routing" icon="switch-horizontal" subtitle="A worked request, the two gateways and two filters it crosses, API-key auth, and what `model: MoM` does." >}}
  {{< card link="/docs/platform/ai-platform/autoscaling-and-gpu/" title="Autoscaling & GPUs" icon="chip" subtitle="Three KEDA triggers on leading vLLM signals, the scale-to-zero deadlock, the gpu-l4 NodePool and S3 Files weights." >}}
  {{< card link="/docs/platform/ai-platform/coding-clients/" title="Coding clients" icon="terminal" subtitle="Connecting OpenCode, Continue and OpenWebUI to the gateway — authentication, model IDs, and troubleshooting." >}}
  {{< card link="/docs/platform/ai-platform/roadmap/" title="Roadmap" icon="map" subtitle="What's still open on the upgrade path — bigger models, multi-replica serving, and per-tenant cost attribution." >}}
{{< /cards >}}
