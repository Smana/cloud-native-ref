# InferenceService Composition

Crossplane composition for self-hosted LLM inference on EKS. Renders a vLLM
Deployment plus all surrounding plumbing: KEDA `ScaledObject` with prometheus
triggers on leading vLLM saturation metrics ([SPEC-001](../../../../../../docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md)),
GPU node selection (Karpenter `gpu-l4` NodePool), zero-trust networking,
weights mounted from a shared S3 Files filesystem (ADR-0004),
observability scrapes / rules, and an optional one-shot weights-preload Job.

Phase 3 of the self-hosted LLM platform feature.

## API summary

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: InferenceService
metadata:
  name: xplane-<model-slug>     # constitution: xplane-* prefix
  namespace: llm
spec:
  model:
    repository: <hf-repo>          # required, e.g. Qwen/Qwen3-8B
    revision: <sha-or-tag>         # pin to a HuggingFace commit SHA
    quantization: fp16             # fp16 | fp8 | awq | gptq | bitsandbytes
    contextWindow: 4096            # vLLM --max-model-len
    toolCallParser: hermes         # optional; vLLM tool-call parser name
    preload:
      enabled: false               # CL-3 (rec A): composition-rendered Job
  gpu:
    count: 1                       # nvidia.com/gpu request
    minVRAM: 16Gi                  # informational
  routing:                         # consumed by Semantic Router classifier config
    tier: medium                   # small | medium | large
    specialty: general             # general | code | code-fim | math | guardrail | multilingual
  scaling:
    minReplicas: 1                 # SPEC-001 default: always-warm. 0 is allowed but accepts first-request failure (no queueing layer).
    maxReplicas: 3                 # KEDA scales 1→max on leading saturation triggers (running-ratio + KV-cache util).
  cache:
    kvOffload: { enabled: false, sizeGB: 16 }   # vLLM --cpu-offload-gb
    prefixCache: { enabled: false }             # vLLM --enable-prefix-caching
  loraAdapters:                                 # optional; v0.6.0+ — see "LoRA adapters" section
    - name: <client-facing-model-id>            # kebab-case, e.g. xplane-qwen-coder-sql
      repository: <hf-org>/<hf-repo>
      revision: <sha-or-tag>                    # defaults to "main"
  gateway:                         # optional; v0.7.0+ (SPEC-002) — see "AI Gateway routing" section
    enabled: false                 # composition renders Backend + AIServiceBackend + AIGatewayRoute
    canary:                        # optional; weighted LoRA canary (requires a loraAdapters match)
      adapter: <lora-name>         # must equal a loraAdapters[].name (CEL-enforced at the XRD)
      weightPercent: 15            # 1–99; percent of base-model traffic sent to the adapter
  route:
    enabled: false                 # usually false — traffic flows through the AI Gateway / SR
    parentGateway: platform-tailscale-general
    parentGatewayNamespace: infrastructure
    hostname: <short-host>         # appended with .priv.cloud.ogenki.io
  weightsFileSystem:
    subPath: <claim-name>          # subdir under the shared S3 Files mount; defaults to claim name
  externalSecrets:
    - name: hf-token
      remoteRef: /platform/llm/hf_token
      refreshInterval: 1h
  envFromSecrets:
    - hf-token                     # pre-existing Secrets shared across claims
```

## LoRA adapters

`loraAdapters` (v0.6.0+) is an optional list. When non-empty, the composition emits
`--enable-lora --max-loras N --max-lora-rank 64 --lora-modules <name>=/models/loras/<name>`
into vLLM args and extends the preload Job to download each adapter into
`/models/loras/<name>/` on the shared S3 Files PVC. Each adapter is
addressable as a separate model name through the OpenAI `/v1/chat/completions`
`model` field; AI Gateway routing for the new names lives in
`apps/base/ai/llm/ai-gateway-routes/route.yaml` (one matchRule per adapter,
all pointing at the same `xplane-<base>` AIServiceBackend).

```yaml
spec:
  loraAdapters:
    - name: xplane-qwen-coder-sql-dpo
      repository: jk200201/qwen2.5-coder-7b-sql-dpo
      revision: main
    - name: xplane-qwen-coder-securecode
      repository: scthornton/qwen2.5-coder-7b-securecode
      revision: main
```

LoRA support requires vLLM ≥ 0.7 (current pinned `v0.8.5` satisfies this).
Empty/absent list = no LoRA enabled (regression-safe).

## AI Gateway routing

`gateway` (v0.7.0+, [SPEC-002](../../../../../../docs/specs/002-composition-owned-gateway-routing/spec.md))
makes the composition own the claim's Envoy AI Gateway wiring instead of the
hand-written entries in `apps/base/ai/llm/ai-gateway-routes/route.yaml`. When
`gateway.enabled`, the module renders:

- a `Backend` named `<claim>-direct` pointing at the vLLM Service FQDN
  (`<claim>.<namespace>.svc.cluster.local:8000`),
- an `AIServiceBackend` `<claim>` (`schema: OpenAI`, referencing the Backend),
- an `AIGatewayRoute` `<claim>` bound to the shared `ai-gateway` Gateway in
  `envoy-ai-gateway-system`.

The route carries a **base rule** (header `x-ai-eg-model == <claim>`) plus **one
pin rule per `loraAdapters[]` entry** (header `x-ai-eg-model == <claim>-<adapter>`),
all served by the same base pod — vLLM dispatches on the request-body `model`
field.

### Readiness latch (FR-002)

The `AIGatewayRoute` is **withheld** until the claim's Deployment reports
`Available=True`, so the gateway never routes to a pod that cannot serve. Once
the route has been created it is **latched** — a subsequent transient Deployment
unavailability never withdraws it (the composition observes the route in cluster
state and keeps rendering it). This avoids route flapping under rolling restarts
or brief pod churn. The `Backend` and `AIServiceBackend`(s) are static-ready
(always applied when `gateway.enabled`).

### Weighted LoRA canary

Setting `gateway.canary` splits the base rule's traffic between the base model
and one of its LoRA adapters (same pod, zero extra GPU). It renders a second
`AIServiceBackend` `<claim>-canary` (same Backend) so the rule has two named
backendRefs:

- `<claim>` at `weight: 100 - weightPercent`,
- `<claim>-canary` at `weight: weightPercent`, with
  `modelNameOverride: <claim>-<adapter>` (rewrites the upstream model name so
  vLLM serves the adapter).

Explicit `x-ai-eg-model == <claim>-<adapter>` requests stay pinned 100% on the
base pod via the adapter's pin rule — the canary only rebalances the base-model
model name. `gateway.canary.adapter` must match a `loraAdapters[].name`
(CEL-enforced at the XRD) and `weightPercent` is bounded 1–99.

When `gateway.enabled`, `status.modelEndpoint` is set to
`https://llm.priv.cloud.ogenki.io/v1` (the platform's external OpenAI-compatible
entry point).

## Resources rendered

| Resource | Condition | Notes |
|---|---|---|
| `Deployment` | always | vLLM container, GPU request, toleration, `gpu-l4` nodeSelector, Recreate strategy |
| `Service` | always | ClusterIP `:8000` (vLLM OpenAI server) |
| `ServiceAccount` | always | Token mounted; no IAM binding (weights via CSI mount per ADR-0004) |
| `ScaledObject` (KEDA core) | always | Prometheus triggers on **leading** vLLM saturation metrics: `running/max-num-seqs` ratio + `gpu_cache_usage_perc`. Replaces the legacy `HTTPScaledObject` + `HPA` rendering (composition v0.5.0+, [SPEC-001](../../../../../../docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md)). |
| `HTTPRoute` | `route.enabled` | Per-model HTTPRoute on the platform Tailscale gateway (otherwise reach via the AI Gateway / SR) |
| `Backend` (`<claim>-direct`) | `gateway.enabled` | Envoy Gateway `Backend` → vLLM Service FQDN `:8000`. Static-ready |
| `AIServiceBackend` (`<claim>`) | `gateway.enabled` | OpenAI-schema AI backend referencing the `Backend`. Static-ready |
| `AIServiceBackend` (`<claim>-canary`) | `gateway.canary` set | Second AI backend (same `Backend`) so the route rule can carry two named backendRefs. Static-ready |
| `AIGatewayRoute` (`<claim>`) | `gateway.enabled` **and** Deployment `Available` (latched) | Base rule (`x-ai-eg-model == <claim>`) + one pin rule per LoRA adapter. Withheld until the Deployment is ready, then latched (never withdrawn on transient unavailability). Ready when `status.conditions[Accepted]=True` |
| XR `status.modelEndpoint` | `gateway.enabled` | XR status patched to `https://llm.priv.cloud.ogenki.io/v1` via the desired-composite (dxr) |
| `CiliumNetworkPolicy` (serving) | always | Default-deny + explicit allow on the long-lived serving pod (DNS only egress + ingress from AI Gateway data-plane, SR, vmagent) |
| `CiliumNetworkPolicy` (preload) | `model.preload.enabled` | Separate policy on the one-shot Job pod (DNS, AWS API, world:443 for HF, host:80 for EKS Pod Identity Agent) |
| `ExternalSecret(s)` | per `externalSecrets` entry | AWS Secrets Manager → Kubernetes Secret |
| `VMServiceScrape` | always | Scrapes `:8000/metrics` (vLLM Prometheus exposition) |
| `VMRule` | always | Cold-start budget + error-rate alerts (overridable) |
| `Job` (model preload) | `model.preload.enabled` | Idempotent — short-circuits if a `.preload-complete` marker matches `<repo>@<revision>`, or if `config.json` is already in the directory; HF download is itself idempotent on file checksums |

Weights themselves come from the shared S3 Files PV/PVC `llm-models` (provisioned
out-of-band in `apps/base/ai/llm/models-pvc.yaml` because Crossplane v2
namespaced XRs cannot render cluster-scoped resources). Each claim mounts the
PVC at `/models` with `subPath = <claim-name>` for filesystem isolation.

## Examples

- [`infrastructure/base/crossplane/configuration/examples/inferenceservice-basic.yaml`](../../examples/inferenceservice-basic.yaml) — minimal claim, single GPU, defaults applied (always-warm, no preload).
- [`infrastructure/base/crossplane/configuration/examples/inferenceservice-complete.yaml`](../../examples/inferenceservice-complete.yaml) — full feature set: preload Job, HTTPRoute, KV offload + prefix cache, ExternalSecret, LoRA adapter, and composition-owned AI Gateway routing with a weighted canary.

## Validation

```bash
# from module dir
kcl fmt .
kcl test . -Y settings-example.yaml --fail-fast
kcl run  . -Y settings-example.yaml > /tmp/render.yaml

# from repo root (after OCI publish)
./scripts/validate-kcl-compositions.sh
```

The local `kcl run` / `kcl test` paths work without any external deps.
`crossplane render` (4th stage of the validation script) requires the OCI
module to be published — done automatically by `.github/workflows/crossplane-modules.yml`
on PR (preview tag `0.4.0-pr<N>`) and on merge to main (`0.4.0` + `latest`).

## Deviations from the generic `App` composition

`App` is CPU-only and assumes scale-up baseline. `InferenceService` differs:

- **GPU request + toleration + nodeSelector** — pods land on the `gpu-l4` Karpenter NodePool only.
- **`Recreate` strategy** — GPUs are scarce; rolling-update surge would block scheduling.
- **KEDA `ScaledObject` on leading saturation signals** ([SPEC-001](../../../../../../docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md)) — `minReplicas: 1` is the default (always warm). KEDA scales 1→max on `running/max-num-seqs` ratio + `gpu_cache_usage_perc`, reacting *before* the queue forms. `minReplicas: 0` is allowed for demo cold-start showcases but accepts first-request failure (no queueing layer; client must retry).
- **Default-deny network policies are split per workload** — serving Deployment gets a tight CNP (DNS only egress); preload Job gets a broader CNP (HF/world:443, AWS API, EKS Pod Identity Agent). Each pod template carries `app.kubernetes.io/component=inference` or `=preload` so Cilium scopes the right policy.
- **Weights via CSI mount, not S3 API** (ADR-0004) — serving pods reach weights through the shared S3 Files PV/PVC, no per-claim EPI. Preload Job uses the shared writable `xplane-llm-models-preload` EPI.
- **CL-3 model preload Job** — composition-rendered, two-tier idempotency (marker file + `config.json` short-circuit). Default off (`model.preload.enabled: false`).

## Clarifications cross-reference

- **CL-3** (preload trigger): recommendation A — composition renders Job when `model.preload.enabled: true`.
- **CL-5** (App XR `gpu` field): recommendation A — `App` stays CPU-only; this XRD is fully separate.
- **CL-6** (NodePool capacity ceiling): A — `nvidia.com/gpu: 4` cap on the `gpu-l4` NodePool.
- **CL-8** (model storage): A — S3 + S3 Files filesystem (rustfs reassessment deferred); see ADR-0004.

## Naming note

The plan draft used `kind: XInferenceService`. Repo convention (App, SQLInstance, EPI) is to omit the `X` prefix on the kind itself; the `xplane-*` prefix lives on the resource *name*. This composition follows repo convention: `kind: InferenceService`, plural `inferenceservices`, dir `inference-service/`.
