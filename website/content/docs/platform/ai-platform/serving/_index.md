---
title: Serving
weight: 10
description: An OpenAI-compatible vLLM serving platform behind Envoy AI Gateway, declared one model per Crossplane claim — off by default until three independent gates are all released.
lastVerified: 2026-08-30
---

An OpenAI-compatible inference platform on EKS: vLLM on L4 spot GPUs, fronted
by Envoy AI Gateway, scaled by KEDA on vLLM saturation signals, and declared
as a single Crossplane
[`InferenceService` claim]({{< relref "/docs/platform/ai-platform/serving/inference-service.md" >}})
per model.

{{< callout type="warning" >}}
**This platform is off by default.** Three independent gates must all be
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
| **GPUs** | Karpenter `gpu-l4` NodePool — single-GPU `g6` spot-first instances, Bottlerocket NVIDIA AMI, capped at 4 GPUs |
| **Composition** | `crossplane-inference-service` KCL module `0.9.0`, pinned inside `crossplane-configuration-aws:v0.9.0` |

## Turning it on

The AWS gate and the two Kubernetes gates are independent of each other, so releasing one does not
bring the others along — but `llm-platform` itself `dependsOn` `ai-gateway`, so the second
Kubernetes command must run before the third:

```bash
# Gate 1 — AWS side (S3 Files filesystem + IAM). Terramate stack tagged
# `opt-in`; skipped unless TM_LLM_PLATFORM_ENABLED=true (verified in
# opentofu/aws/llm-platform/workflows.tm.hcl — unset or != "true" echoes [skip]
# and exits 0).
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/aws/llm-platform script run deploy

# Gate 2 — Kubernetes side, gateway layer. llm-platform depends on this
# umbrella, so it must resume first or llm-platform stalls on
# "dependency 'flux-system/ai-gateway' is not ready".
flux resume kustomization ai-gateway -n flux-system

# Gate 3 — Kubernetes side, GPU models. The umbrella Flux Kustomization ships
# suspended (spec.suspend: true, clusters/aws-0/llm-platform.yaml).
flux resume kustomization llm-platform -n flux-system
```

The umbrella aggregates **5** child Flux Kustomizations under
`clusters/aws-0-llm-platform/`:

| Child | Renders | Path |
|---|---|---|
| `runtimeclass-nvidia` | `RuntimeClass nvidia` | `infrastructure/base/runtimeclass-nvidia` |
| `llm-platform-gpu-nodepools` | Karpenter `gpu-l4` NodePool + EC2NodeClass | `infrastructure/base/karpenter-nodepools-gpu` |
| `llm-platform-apps` | The `InferenceService` claims + OpenWebUI | `apps/llm` |
| `llm-platform-security-epi` | The preload Job's EKS Pod Identity | `security/base/epis-llm` |
| `llm-platform-promptfoo` | Nightly agent-eval CronJob | `tooling/base/promptfoo` |

The gateway layer these children attach to (Envoy Gateway, the Envoy AI Gateway, the Semantic
Router and the `ai-gateway` Gateway) is a separate umbrella, `ai-gateway`, under
`clusters/aws-0-ai-gateway/`. It is CPU only and suspended by default: resume it before
`llm-platform`, which depends on it.

That directory is a **sibling** of `clusters/aws-0/`, not a child, on
purpose: `flux-system` syncs `clusters/aws-0/` recursively, so a nested
path would be auto-discovered and applied — bypassing the suspend gate
entirely.

### On `gcp-0`

`gcp-0` has **no OpenTofu gate**: the weights bucket is a Crossplane claim
rather than an OpenTofu stack, so there is no `TM_LLM_PLATFORM_ENABLED`.
The two Kubernetes gates match aws-0's: `clusters/gcp-0/ai-gateway.yaml`,
then `clusters/gcp-0/llm-platform.yaml`, which depends on it (both
`spec.suspend: true`). Weights are served from a GCS bucket over the Cloud
Storage FUSE CSI driver instead of an S3 Files POSIX mount — see
[ADR-0021]({{< relref "/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md" >}})
for why, including what it gives up. Why the umbrella is still suspended, and
what the first resume proved, is on the
[status page]({{< relref "/docs/platform/ai-platform/status.md#serving" >}}).

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

Known gaps live on the
[status page]({{< relref "/docs/platform/ai-platform/status.md#known-gaps" >}}).

{{< cards >}}
  {{< card link="/docs/platform/ai-platform/serving/inference-service/" title="The InferenceService claim" icon="document-text" subtitle="One model, one YAML file — a complete claim with its reasoning intact, what it renders, and every field it accepts." >}}
  {{< card link="/docs/platform/ai-platform/serving/autoscaling-and-gpu/" title="Autoscaling & GPUs" icon="chip" subtitle="Three KEDA triggers on leading vLLM signals, the scale-to-zero deadlock, the gpu-l4 NodePool and S3 Files weights." >}}
{{< /cards >}}
