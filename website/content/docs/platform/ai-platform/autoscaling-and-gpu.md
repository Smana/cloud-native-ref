---
title: Autoscaling & GPUs
weight: 40
description: Three KEDA triggers on leading vLLM signals, why minReplicas is never zero, and the GPU and storage foundation underneath.
lastVerified: 2026-08-27
---

Scaling a GPU workload is not scaling a web service. A cold start is 30–90
seconds of model load and CUDA-graph compilation, a replica costs an entire
L4, and by the time a lagging signal like request count has moved, the users
who caused it have already waited. Everything below follows from that.

## Three triggers, OR-combined

One KEDA `ScaledObject` per model, always rendered, with three Prometheus
triggers evaluated against VictoriaMetrics — any one at or above threshold
drives a scale-up. Verified against the pinned KCL module
(`apis/inferenceservice/kcl/main.k` in `Smana/crossplane-configuration`):

| # | Signal | Query | Default threshold |
|---|---|---|---|
| 1 | batch saturation | `max(vllm:num_requests_running{model_name="X"}) / scalar(vector(<maxNumSeqs>))` | `0.7` |
| 2 | KV-cache pressure | `max(vllm:kv_cache_usage_perc{model_name="X"})` | `0.6` |
| 3 | queue depth | `max(vllm:num_requests_waiting{model_name="X"})` | `8` |

All three are **leading** signals: they fire before the batch saturates,
before the cache evicts, before the queue builds. And `max()` rather than an
average is deliberate — it tracks the hottest replica instead of a fleet mean
that would hide it behind idle capacity.

Defaults: `pollingInterval: 15s`, `cooldownPeriod: 300s`.

Trigger 1's denominator is the claim's own `model.maxNumSeqs`. That field is
not only a memory setting: raising it to fit more concurrent requests also
raises the bar for a scale-up, because saturation is measured as a fraction
of it.

![The three KEDA triggers OR-combined against VictoriaMetrics, the two metric families vLLM exposes, and the dashboards and alerts they feed](/images/diagrams/llm-platform-3.svg)

## Why `minReplicas` is never zero

Scale-to-zero on a Prometheus-driven autoscaler is a deadlock, not a
trade-off: at zero replicas there is no pod, so there is no
`vllm:num_requests_running` series, so no trigger can fire, so nothing ever
scales back up. The metric that would wake the model only exists once the
model is already awake.

That deadlock was first worked around with the KEDA HTTP add-on, which put a
proxy in the data path and scaled on a lagging request count. It is **no
longer used**. What replaced it is simply `minReplicas: 1` plus leading
signals — the deadlock disappears once a replica is always present, and the
AI Gateway routes directly to each vLLM Service with no scaling proxy in
front of the fleet.

The cost is explicit rather than hidden: four models at `min=1` hold four
GPUs continuously, whether or not anyone sends a request.

{{< callout type="warning" >}}
A fourth, opt-in trigger on the Gateway API Inference Extension's
InferencePool saturation gauge is specified
(`docs/specs/done/2026-Q3/011-inferencepool-saturation-keda/spec.md`) but
**could not be verified**: the pinned KCL module renders only the three
triggers above, and that spec's own task and review checklists are almost
entirely unchecked. Treat it as not shipped despite living under the `done`
archive, and re-verify before citing it as delivered.
{{< /callout >}}

## The GPU foundation

Karpenter NodePool `gpu-l4`:

- **Single-GPU `g6` instances only.** The NodePool explicitly excludes
  multi-GPU SKUs such as `g6.12xlarge` and `g6.48xlarge`, so one claim can
  never consume the whole GPU budget.
- **Spot-first**, with the reclaim consequence below.
- **Bottlerocket NVIDIA AMI.** There is no NVIDIA device-plugin DaemonSet —
  the Bottlerocket NVIDIA variant advertises `nvidia.com/gpu` through the
  kubelet natively.
- **Capped at `nvidia.com/gpu: "4"`** across the whole pool.
- **`consolidationPolicy: WhenEmpty`**, not the default
  `WhenEmptyOrUnderutilized`. An always-warm model serving one request a
  minute looks underutilised to Karpenter, and consolidating its node would
  trigger exactly the cold start `minReplicas: 1` exists to avoid.

Spot reclaim can still force a 30–90s multi-AZ PVC re-attach. That is an
accepted trade for a personal platform and would not be for a team tier.

## Weights on shared storage

An Amazon S3 Files filesystem — POSIX semantics over S3 — is mounted RWX at
`/models` by both the preload Job and the serving pod, each under its own
`subPath`.

One operational must-know: the PV is provisioned out-of-band, with a
hand-copied `volumeHandle` in `apps/aws-0/llm/models-pvc.yaml` that every
`tofu apply` of `opentofu/aws/llm-platform/` regenerates. After a rebuild,
fetch it with `tofu -chdir=opentofu/aws/llm-platform output -raw volume_handle`,
update that file, and delete the existing PV+PVC so Flux recreates them
(`volumeHandle` is immutable) — otherwise every mount fails against the old
filesystem id.

The consequence worth understanding: **the serving pod never fetches
weights itself.** They arrive over the CSI mount, so each claim's serving
ServiceAccount carries only a per-claim **read-only** EKS Pod Identity,
scoped to its own weights prefix and rendered by the composition — write
access belongs solely to the shared preload Job's identity
(`xplane-llm-models-preload`). That is also why the serving pod's egress
policy can be kube-dns only, while `world:443` is granted solely to the
short-lived preload Job — the runtime pod cannot reach HuggingFace even in
principle.

[ADR-0004]({{< relref "/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md" >}})
records why this replaced an init-container sync, and
[ADR-0003]({{< relref "/docs/decisions/0003-vllm-production-stack-over-kserve.md" >}})
why vLLM Production Stack was chosen over KServe + llm-d.
