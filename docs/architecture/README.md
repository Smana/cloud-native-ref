# Architecture diagrams

Drawio (`.drawio`) files. Open with the [drawio desktop app](https://www.drawio.com/) or the [VS Code "Draw.io Integration" extension](https://marketplace.visualstudio.com/items?itemName=hediet.vscode-drawio).

## Files

- [`llm-platform.drawio`](llm-platform.drawio) — self-hosted LLM platform on EKS. Request flow, model-weights flow, GitOps subsystems (Flux + Crossplane), and scaling behaviour.

## LLM platform: how a request flows

The diagram captures it visually; this section is the textual companion for the actual control + data path of a single OpenAI-compatible request.

```
                ┌──────────────────────────┐
  developer ──► │ Tailscale (private VPN)  │
   (laptop)    └──────────────┬───────────┘
                              │ HTTPS, auth via Tailscale ACL
                              ▼
        ┌──────────────────────────────────────────┐
        │ Cilium Tailscale Gateway                 │  Gateway API + cilium-envoy
        │ host: llm.priv.cloud.ogenki.io           │  (DaemonSet, eBPF service xlat)
        └──────────────────────┬───────────────────┘
                               │ HTTPRoute → Service ClusterIP
                               ▼
   ┌──────────────────────────────────────────────────────────────┐
   │ Envoy AI Gateway data plane (envoy-gateway-system/ai-gateway)│
   │                                                              │
   │  ① SecurityPolicy verifies `Authorization: Bearer <key>`     │
   │     (api-keys-externalsecret → raw-key Secret; Envoy strips  │
   │     `Bearer ` from the header before the byte-compare)       │
   │  ② AI Gateway body parser sets `x-ai-eg-model` from          │
   │     body.model. For `body.model == "MoM"` the AIGatewayRoute │
   │     extension calls SR's HTTP classifier at                  │
   │     `vllm-semantic-router.llm:8080/api/v1/classify/intent`   │
   │     to rewrite x-ai-eg-model.                                │
   │  ③ AIGatewayRoute matches x-ai-eg-model → AIServiceBackend → │
   │     Backend (FQDN of the vLLM Service)                       │
   │  ④ Direct route to `xplane-<model>.llm.svc:8000` (no proxy   │
   │     hop, no interceptor — SPEC-001)                          │
   └────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
                ┌──────────────────────────┐
                │ vLLM pod (GPU L4 spot)   │   /v1/chat/completions
                │ /models mounted from S3  │   --enable-auto-tool-choice
                │ Files (POSIX over S3)    │   --tool-call-parser hermes
                └──────────────────────────┘
```

### Key resources by responsibility

| Concern | Resource | Where |
|---|---|---|
| Public/private ingress | Tailscale Cilium Gateway, HTTPRoute | `infrastructure/base/gapi/`, `infrastructure/base/envoy-ai-gateway/httproute.yaml` |
| Gateway data plane | Envoy AI Gateway 0.5.0 + Envoy Gateway 1.7.0 | `infrastructure/base/envoy-{,ai-}gateway/` |
| API-key authentication | `SecurityPolicy.apiKeyAuth` (Authorization header, ForwardClientIDHeader, sanitize) | `infrastructure/base/envoy-ai-gateway/security-policy.yaml` |
| API-key store (raw values) | ExternalSecret → Secret `ai-gateway-api-keys` (sourced from AWS SM `platform/llm/api-keys`); Envoy strips `Bearer ` from the request header before comparison, so the stored value is the raw key | `infrastructure/base/envoy-ai-gateway/api-keys-externalsecret.yaml` |
| Per-model routing rule | AIGatewayRoute (4 rules, one per `xplane-<model>` header value) | `apps/base/ai/llm/ai-gateway-routes/route.yaml` |
| Prompt classification (`MoM` only) | vllm-semantic-router HTTP classifier (`/api/v1/classify/intent` on :8080) | `infrastructure/base/vllm-semantic-router/` |
| Model serving | vLLM Deployments + Services + KEDA `ScaledObject` per claim | InferenceService XR (Crossplane composition) |
| Model weights | S3 Files filesystem (POSIX-over-S3) mounted at `/models` via EFS CSI driver | `opentofu/llm-platform/`, `apps/base/ai/llm/models-pvc.yaml` |
| Web UI | OpenWebUI → `OPENAI_API_BASE_URL` → AI Gateway data plane (Bearer-token auth) | `apps/base/openwebui/` |
| IDE clients | OpenCode (TUI) + Continue (VSCode) → OpenAI-compatible endpoint | external configs; see [`docs/coding-clients.md`](../coding-clients.md) |

### How scaling works

Per [SPEC-001](../specs/0001-llm-platform-prometheus-autoscaling/spec.md), every model defaults to `minReplicas: 1` (always warm) with a KEDA `ScaledObject` driven by **leading vLLM saturation metrics**:

- `vllm:num_requests_running / max-num-seqs` ratio (threshold 0.7) — fires before the batch saturates.
- `vllm:gpu_cache_usage_perc` (threshold 0.8) — fires before KV cache evicts.

The legacy KEDA HTTP add-on (proxy hop in the data path, lagging request-rate trigger) is no longer used; the AI Gateway routes directly to each vLLM Service. End-to-end scale-up reaction: ~75-135s under realistic load (vs. minutes once the queue forms with lagging metrics).

The 4-model fleet (`xplane-qwen-coder-fim`, `xplane-qwen-coder`, `xplane-qwen3-8b`, `xplane-llamaguard3-1b`) at `min=1` consumes 4× L4 spot instances steady state. The `gpu-l4` Karpenter NodePool's `nvidia.com/gpu: 4` cap means a single claim can scale to a maximum of `min + (cap - sum_of_other_mins)` — an intentional cost ceiling. Demo `min=0` overrides per claim are still allowed (composition supports it) but accept the first-request failure mode (no queueing layer; client must retry).

### How a Crossplane `InferenceService` claim renders

A claim like `apps/base/ai/llm/qwen3-8b.yaml` is a 30-line spec; the composition under `infrastructure/base/crossplane/configuration/kcl/inference-service/` renders it into ~10 Kubernetes resources:

- Deployment (vLLM container with computed args from `model.{quantization, contextWindow, toolCallParser, maxNumSeqs}`, `cache.{prefixCache, kvOffload}`)
- Service (ClusterIP, port 8000)
- ServiceAccount (no IAM binding — weights via CSI mount per ADR-0004)
- KEDA `ScaledObject` (prometheus triggers on running-ratio + KV-cache util)
- CiliumNetworkPolicy (default-deny, ingress from AI Gateway data plane + SR + vmagent, egress to kube-dns + apiserver + S3 Files mount)
- Optional HTTPRoute (only when `route.enabled`)
- VMServiceScrape (vLLM `/metrics` → VictoriaMetrics)
- VMRule (per-model latency + error alerts)
- Optional Idempotent preload Job (HuggingFace → `/models/<subPath>/<revision>/`) — runs once when `model.preload.enabled: true`

Composition published as an OCI artifact to GHCR; consumed by `function-kcl` at render time.

### Detailed docs

- [`docs/ai.md`](../ai.md) — full AI/ML platform architecture, fleet shape, scaling model, observability hooks, ADRs.
- [`docs/coding-clients.md`](../coding-clients.md) — OpenCode / Continue / OpenWebUI client configuration (auth + smoke tests).
- [`docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md`](../specs/0001-llm-platform-prometheus-autoscaling/spec.md) — the autoscaling redesign that replaced the original KEDA HTTP add-on path.
- [`docs/decisions/0003-vllm-production-stack-over-kserve.md`](../decisions/0003-vllm-production-stack-over-kserve.md) — vLLM Production Stack over KServe + llm-d.
- [`docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md`](../decisions/0004-amazon-s3-files-for-model-weights-storage.md) — model-weights mount via S3 Files.

## Conventions

- One topic per file, kebab-case filename.
- AWS components: `mxgraph.aws4` icon namespace (AWS 2026 icon style).
- Kubernetes primitives: `mxgraph.kubernetes.icon` namespace where helpful, plain rectangles otherwise.
- Edge colors: blue = request flow, green = storage / data flow, orange dashed = GitOps reconciliation, red dashed = planned / blocked.
