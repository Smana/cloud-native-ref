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
  engineArgs:                      # optional; v0.8.0+ (SPEC-003) — see "Engine args" section
    - --kv-cache-dtype=fp8         # verbatim vLLM CLI tokens, appended after managed flags
    - --enforce-eager              # reserved flags (--model, --port, …) rejected at admission
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
    canaries:                      # optional; weighted LoRA canaries (max 4; each requires a loraAdapters match)
      - adapter: <lora-name>       # must equal a loraAdapters[].name (CEL-enforced at the XRD)
        weightPercent: 15          # 1–99; percent of base-model traffic sent to the adapter
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

## Engine args

`engineArgs` (v0.8.0+, [SPEC-003](../../../../../../docs/specs/003-inferenceservice-spec-engineargs-escape/spec.md))
is an optional escape hatch for verbatim vLLM CLI flags that have no dedicated
`spec` field. Each entry is a **single token** — either `--flag` or
`--flag=value`, never `--flag value` split across two array items (the CEL
denylist rejects any entry that does not start with `--`). The composition does
**not** transform or re-validate these; the XRD admission CEL is the single
enforcement point.

**Ordering guarantee.** `engineArgs` are appended **last**, after every
composition-managed flag. A user therefore cannot re-order or shadow a managed
flag by supplying it again — and the reserved flags below are rejected at
admission outright, so there is no last-writer-wins ambiguity.

**Admission behavior.** Values are checked *structurally* (single `--` token)
and *against the reserved denylist* below — nothing more. `engineArgs` are **not**
validated against the vLLM CLI: an unknown or malformed flag (e.g. a typo, or a
value vLLM rejects) is accepted at admission and **fails at container start**
(the vLLM process exits, the pod crash-loops), not at `kubectl apply` time.

```yaml
spec:
  engineArgs:
    - --kv-cache-dtype=fp8
    - --enforce-eager
```

### Reserved flags (rejected at admission)

These 16 flags are composition-managed and rejected by the XRD CEL denylist —
set them through the curated `spec` field instead. Keep this table in lockstep
with the denylist in `inference-service-definition.yaml` and the managed flags
in `main.k`.

| Reserved flag | Use instead |
|---|---|
| `--model` | `spec.model.repository` (composition sets the local weights path) |
| `--served-model-name` | none — the served model name is the claim name (`metadata.name`) |
| `--max-model-len` | `spec.model.contextWindow` |
| `--max-num-seqs` | `spec.model.maxNumSeqs` (it is the KEDA scaling denominator) |
| `--gpu-memory-utilization` | none — fixed at `0.92` |
| `--quantization` | `spec.model.quantization` |
| `--enable-prefix-caching` | `spec.cache.prefixCache.enabled` |
| `--cpu-offload-gb` | `spec.cache.kvOffload.{enabled,sizeGB}` |
| `--enable-auto-tool-choice` | `spec.model.toolCallParser` |
| `--tool-call-parser` | `spec.model.toolCallParser` |
| `--enable-lora` | `spec.loraAdapters` |
| `--max-loras` | `spec.loraAdapters` |
| `--max-lora-rank` | `spec.loraAdapters` (rank fixed at 64) |
| `--lora-modules` | `spec.loraAdapters` |
| `--port` | none — **serving contract**: the vLLM port is fixed at 8000. The Service, liveness/readiness probes, and the gateway `Backend` all depend on it |
| `--host` | none — **serving contract**: the listen address is fixed. The Service, probes, and gateway `Backend` all depend on it |

> `--port` and `--host` are reserved even though the composition never emits
> them explicitly (vLLM's defaults already match the serving contract). They are
> denied because a user override would silently break the Service/probes/Backend
> port-8000 assumption.

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
pin rule per `loraAdapters[]` entry** (header `x-ai-eg-model == <adapter-name>`,
matched verbatim — adapter names are fully-qualified, e.g.
`xplane-qwen-coder-sql-dpo`), all served by the same base pod — vLLM dispatches on
the request-body `model` field.

### Readiness latch (FR-002)

The `AIGatewayRoute` is **withheld** until the claim's Deployment reports
`Available=True`, so the gateway never routes to a pod that cannot serve. Once
the route has been created it is **latched** — a subsequent transient Deployment
unavailability never withdraws it (the composition observes the route in cluster
state and keeps rendering it). This avoids route flapping under rolling restarts
or brief pod churn. The `Backend` and `AIServiceBackend`(s) are static-ready
(always applied when `gateway.enabled`).

### Weighted LoRA canaries

Setting `gateway.canaries` (an array, max 4) splits the base rule's traffic
between the base model and one or more of its LoRA adapters (same pod, zero extra
GPU). Each entry renders its own `AIServiceBackend` `<claim>-canary-<i>` (same
Backend) so the base rule carries one named backendRef per canary alongside the
base-model backendRef:

- `<claim>` at `weight: 100 - sum(weightPercent)` (the base model always retains
  traffic — the sum of all canary weights is CEL-bounded to ≤ 99),
- `<claim>-canary-<i>` at `weight: weightPercent` for each entry `i`, with
  `modelNameOverride: <adapter-name>` (the adapter's own name, verbatim —
  rewrites the upstream model name so vLLM serves the adapter).

Explicit `x-ai-eg-model == <adapter-name>` requests stay pinned 100% on the base
pod via the adapter's pin rule — the canaries only rebalance the base-model model
name. Every `gateway.canaries[].adapter` must match a `loraAdapters[].name`
(CEL-enforced at the XRD), adapter names must be distinct across entries, and
each `weightPercent` is bounded 1–99.

When `gateway.enabled`, `status.modelEndpoint` is populated — see the [Status](#status) table.

## Status

| Field | Condition | Notes |
|---|---|---|
| `status.modelEndpoint` | `gateway.enabled` | External OpenAI-compatible URL `https://llm.<domain>/v1`. The domain comes from the `eks-environment` EnvironmentConfig (`privateDomainName`, populated via Flux `${private_domain_name}`), so the composition stays environment-agnostic; a literal `priv.cloud.ogenki.io` fallback covers clusters whose EnvironmentConfig predates the field |
| `status.servedModels` | always | Topology projection (see below) |
| `status.servedModelsSummary` | always | Comma-joined `servedModels` names; source for the `SERVED MODELS` printer column |

### servedModels (topology projection)

`status.servedModels` (v0.8.0+, [SPEC-003](../../../../../../docs/specs/003-inferenceservice-spec-engineargs-escape/spec.md))
is the set of model names this claim serves — the base model plus one entry per
LoRA adapter. It is a **routing/topology view, NOT a health signal**: an entry
appearing here means the name *would* be served by this claim's vLLM pod, not
that the pod is ready (readiness lives in `status.phase`). It is rendered
unconditionally (independent of `gateway.enabled`).

Each entry:

- `name` — the served model name. Base = the claim name (`metadata.name`);
  adapter = the `loraAdapters[].name` (verbatim).
- `kind` — `base` or `adapter`.
- `canaryWeightPercent` — present **only** on adapter entries that participate
  in a `gateway.canaries[]` split; it echoes that canary's `weightPercent`
  (1–99, percent of base-model traffic routed to the adapter). Absent on the
  base entry and on adapters that are not canaried.

Example (base model + three adapters, two of them canaried):

```yaml
status:
  servedModels:
    - name: xplane-qwen3-8b
      kind: base
    - name: xplane-qwen3-8b-adapter-a
      kind: adapter
      canaryWeightPercent: 10
    - name: xplane-qwen3-8b-adapter-b
      kind: adapter
      canaryWeightPercent: 15
    - name: xplane-qwen3-8b-adapter-c
      kind: adapter
  servedModelsSummary: xplane-qwen3-8b,xplane-qwen3-8b-adapter-a,xplane-qwen3-8b-adapter-b,xplane-qwen3-8b-adapter-c
```

### servedModelsSummary and the printer column

`status.servedModelsSummary` is the comma-joined list of `servedModels[].name`,
surfaced as the `SERVED MODELS` column in `kubectl get inferenceservices`. The
summary field exists **because server-side printer columns render only the first
match of a wildcard JSONPath** — a column sourced from `.status.servedModels[*].name`
would show just the base model, so the composition pre-joins the names into a
single scalar field the column can read directly.

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
| `AIServiceBackend` (`<claim>-canary-<i>`) | per `gateway.canaries[]` entry | One extra AI backend per canary (same `Backend`) so the route rule can carry a distinct named backendRef per canary. Static-ready |
| `AIGatewayRoute` (`<claim>`) | `gateway.enabled` **and** Deployment `Available` (latched) | Base rule (`x-ai-eg-model == <claim>`) + one pin rule per LoRA adapter. Withheld until the Deployment is ready, then latched (never withdrawn on transient unavailability). Ready when `status.conditions[Accepted]=True` |
| XR `status.modelEndpoint` | `gateway.enabled` | XR status patched via the desired-composite (dxr) — see [Status](#status) |
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
