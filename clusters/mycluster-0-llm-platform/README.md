# LLM Platform — opt-in Flux umbrella

The 8 child Flux Kustomizations in this directory are aggregated by the
umbrella at `../mycluster-0/llm-platform.yaml`. This directory is a
**sibling** of `clusters/mycluster-0/` — not a sub-path — so that
`flux-system` (which recursively syncs `clusters/mycluster-0/`) does
not auto-discover the children and bypass the umbrella's
`spec.suspend: true` gate. The umbrella defaults to
`spec.suspend: true`, so none of these children — and therefore none of
the LLM-platform resources — are created on a fresh cluster.

| Child Kustomization | Path | Resources |
|---|---|---|
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | Iris router HelmRelease (`MoM` virtual model + cascade decisions[]) |
| `runtimeclass-nvidia` | `infrastructure/base/runtimeclass-nvidia` | RuntimeClass `nvidia` (Bottlerocket NVIDIA AMI advertises GPU natively — no DaemonSet) |
| `llm-platform-gpu-nodepools` | `infrastructure/base/karpenter-nodepools-gpu` | Karpenter `gpu-l4` NodePool + EC2NodeClass |
| `envoy-gateway` | `infrastructure/base/envoy-gateway` | Envoy Gateway controller (provides the GatewayClass `envoy-ai-gateway` consumes) |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Envoy AI Gateway: AIGatewayRoute → AIServiceBackend → per-model `Backend(FQDN of vLLM Service)` direct (no proxy hop, v0.5.0+) |
| `llm-platform-apps` | `apps/llm` | InferenceService claims + OpenWebUI + AIGatewayRoute |
| `llm-platform-security-epi` | `security/base/epis-llm` | `xplane-llm-models-preload` writable EPI |
| `llm-platform-promptfoo` | `tooling/base/promptfoo` | Nightly Promptfoo eval CronJob — gated under the LLM umbrella so it doesn't fire when SR is suspended |

## Client tier

Three canonical client surfaces consume the platform. Each has a defined role:

| Client | Role | Backing model | Migration spec |
|---|---|---|---|
| **OpenCode TUI** | Experimental occasional-use coding-agent client (Claude Code stays primary) | `xplane-qwen-coder` (primary); per-subagent dispatch (qwen3-8b for review/plan/Explore) | [`Smana/opencode-config`](https://github.com/Smana/opencode-config) — `docs/2026-05-05-opencode-migration-design.md` |
| **Continue VSCode** | IDE inline FIM tab-completion + chat | `xplane-qwen-coder-fim` (FIM); `xplane-qwen-coder` (chat) | per-laptop config in [`docs/coding-clients.md`](../../docs/coding-clients.md) |
| **OpenWebUI** | Web chat for non-coding general questions | `MoM` (SR cascade routes by domain) | configured via `apps/base/openwebui/app.yaml` |

Once enabled, see [`docs/coding-clients.md`](../../docs/coding-clients.md)
for copy-paste configuration and verification with `curl` (covers
common failure modes: 404 model-not-found, missing/invalid API key,
tab-complete falling back to chat).

## Enable

```bash
flux resume kustomization llm-platform -n flux-system
```

After resume, watch the children come up:

```bash
flux get kustomizations -n flux-system | grep llm-platform
```

The OpenTofu side (`opentofu/llm-platform/`) is gated separately with
`$TM_LLM_PLATFORM_ENABLED=true`. Both gates must be released for an
end-to-end deploy. See `opentofu/llm-platform/README.md`.

### One-time AWS Secrets Manager bootstrap

The AI Gateway's API keys live in AWS SM at `platform/llm/api-keys`,
**deliberately outside of OpenTofu** so they survive cluster teardown +
recreation (rotating keys would invalidate every coding-client config —
that pain is worse than the bootstrap step). Three ExternalSecrets
fan out from this single SM entry:

- `envoy-ai-gateway-system/ai-gateway-api-keys` (gateway-side compare)
- `apps/openwebui-llm-api-key` (OpenWebUI's `OPENAI_API_KEY`)
- `promptfoo/promptfoo-llm-api-key` (nightly eval CronJob)

If `aws secretsmanager describe-secret --secret-id platform/llm/api-keys`
returns `ResourceNotFoundException`, seed it once (idempotent — re-running
fails harmlessly with `ResourceExistsException`):

```bash
OPENWEBUI_KEY="sk-$(openssl rand -hex 24)"
PROMPTFOO_KEY="sk-$(openssl rand -hex 24)"
aws secretsmanager create-secret \
  --region eu-west-3 \
  --name platform/llm/api-keys \
  --description "AI Gateway client API keys (raw, no Bearer prefix). JSON: {openwebui_apikey, promptfoo_apikey}" \
  --secret-string "{\"openwebui_apikey\":\"${OPENWEBUI_KEY}\",\"promptfoo_apikey\":\"${PROMPTFOO_KEY}\"}"
```

To onboard a new client identity, add a property to the JSON
(e.g. `developer_apikey`) and append a matching key to the gateway-side
ESO template at `infrastructure/base/envoy-ai-gateway/api-keys-externalsecret.yaml`.

## Disable (preserve cluster state)

```bash
flux suspend kustomization llm-platform -n flux-system
```

Suspend stops reconciliation but does **not** delete in-cluster
resources — children, vLLM pods, GPU NodePool, etc. all stay until
explicitly removed.

## Full teardown

```bash
flux suspend kustomization llm-platform -n flux-system
flux delete kustomization \
  llm-platform-apps llm-platform-gpu-nodepools envoy-ai-gateway envoy-gateway \
  llm-platform-security-epi llm-platform-promptfoo runtimeclass-nvidia vllm-semantic-router \
  -n flux-system --silent

# Then drop the AWS-side resources:
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/llm-platform script run destroy
```

## Whole-cluster destroy (including this LLM stack)

`terramate script run --reverse destroy` from `opentofu/` walks every
stack in reverse dependency order; the LLM platform tofu stack is
opt-in, so the env var must be set:

```bash
# 1. Drop LLM workloads in K8s first (so EFS mount targets and EKS
#    Pod Identity associations have no live consumers when tofu
#    destroy runs).
flux suspend kustomization llm-platform -n flux-system
flux delete kustomization \
  llm-platform-apps llm-platform-gpu-nodepools envoy-ai-gateway envoy-gateway \
  llm-platform-security-epi llm-platform-promptfoo runtimeclass-nvidia vllm-semantic-router \
  -n flux-system --silent

# 2. Walk all stacks in reverse — single y/n prompt at the start.
cd opentofu/
TM_LLM_PLATFORM_ENABLED=true terramate script run --reverse destroy
```

**Data preserved** (orphan policy on the Crossplane Bucket MR — see
`apps/base/ai/llm/s3-bucket.yaml`,
`infrastructure/base/cloudnative-pg/s3-bucket.yaml`,
`security/base/openbao-snapshot/s3-bucket.yaml`):

- `s3://eu-west-3-ogenki-llm-models/` — the Hugging Face model weights
- `s3://eu-west-3-ogenki-cnpg-backups/` — Zitadel + Harbor + image-gallery Postgres backups
- `s3://eu-west-3-ogenki-openbao-snapshot/` — OpenBao raft DR snapshots

The S3 Files filesystem (`fs-...`) and access points are *not*
preserved — they're recreated on the next deploy, and the underlying
S3 bucket data is what they re-mount.

## Fleet shape (post foundation-showcase trim — design doc 2026-05-06)

| Claim | Model | Role | Replicas |
|---|---|---|---|
| `xplane-qwen-coder-fim` | `Qwen2.5-Coder-1.5B` (Base) | FIM inline tab-complete (Continue extension). | min=1 max=1 (always warm) |
| `xplane-qwen-coder` | `Qwen2.5-Coder-7B-Instruct` | Code chat + agentic edits (OpenCode, Continue chat, OpenWebUI `code` route). Function calling. | min=1 max=2 |
| `xplane-qwen3-8b` | `Qwen3-8B` | OpenWebUI default chat + multilingual + 32k context + math/reasoning + general cascade fallback. | min=1 max=2 |
| `xplane-llamaguard3-1b` | `Llama-Guard-3-1B` | Input jailbreak guardrail (SR `prompt_guard`, not category-routed). | min=1 max=3 |

> **All models default `min=1`.** The legacy KEDA HTTP add-on (proxy in
> the data path; request-count trigger) was replaced in v0.5.0 with a
> KEDA `ScaledObject` driven by leading vLLM saturation metrics —
> `running / max-num-seqs` ratio + `gpu_cache_usage_perc`. Scaling
> reacts ahead of saturation rather than after the queue has formed.
> See [SPEC-001](../../docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md)
> for the design rationale. Production keeps `min=1`; demo `min=0`
> overrides are still allowed per-claim but accept the first-request
> failure mode (no queueing layer; client must retry).

Routing modes:

- **Client-deterministic** (OpenCode CLI, Continue VSCode chat / autocomplete) — the client picks `model: xplane-*` directly, bypassing the SR classifier.
- **SR-cascade** (OpenWebUI default — clients send `model: MoM`; SR's `MoM` virtual model classifies and rewrites the body's `model:` field). Decisions:
  - `code` → `xplane-qwen-coder` (with optional CoT toggle for reasoning prompts)
  - `math`/`physics` → `xplane-qwen3-8b` with `use_reasoning: true`
  - `multilingual` → `xplane-qwen3-8b`
  - everything else → `xplane-qwen3-8b`

## Invoking a LoRA adapter

`xplane-qwen-coder` (composition v0.6.0+) ships with two LoRA adapters loaded on top of the base model. They're addressable as separate model names through the OpenAI `/v1/chat/completions` endpoint — vLLM dispatches the adapter weights from the request body's `model:` field, all on the same single-L4 pod:

| Adapter name | HF repository | Specialization |
|---|---|---|
| `xplane-qwen-coder-sql-dpo` | [`jk200201/qwen2.5-coder-7b-sql-dpo`](https://huggingface.co/jk200201/qwen2.5-coder-7b-sql-dpo) | Text-to-SQL (DPO over Spider V1; bare query output, no prose) |
| `xplane-qwen-coder-securecode` | [`scthornton/qwen2.5-coder-7b-securecode`](https://huggingface.co/scthornton/qwen2.5-coder-7b-securecode) | Security-aware code generation (OWASP framing, vulnerable / secure side-by-side) |

```bash
# Base model (general code chat)
curl -s https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "xplane-qwen-coder", "messages": [{"role": "user", "content": "Write a Python function to compute Fibonacci."}]}'

# SQL-DPO adapter — same base pod, different weights
curl -s https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "xplane-qwen-coder-sql-dpo", "messages": [{"role": "user", "content": "Schema: CREATE TABLE users (id INT, name TEXT). Question: count users. SQL:"}]}'

# SecureCode adapter
curl -s https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "xplane-qwen-coder-securecode", "messages": [{"role": "user", "content": "How do I implement JWT auth with refresh tokens in Flask?"}]}'
```

**To add a new adapter**: edit `loraAdapters:` in `apps/base/ai/llm/qwen-coder.yaml`, append a matching `matchRule` to `apps/base/ai/llm/ai-gateway-routes/route.yaml`, and let Flux reconcile. The preload Job re-runs only when the claim spec changes — first reconcile pulls the new adapter from HF into the shared S3 Files PVC, vLLM picks it up on next pod restart.

**Cost / scaling impact**: both adapters loaded simultaneously add ~5–10% inference overhead per request (vLLM `--enable-lora`) and ~30s to cold preload. The base pod is `min=1, max=2` (always warm), so adapter requests don't pay any cold-start cost.
