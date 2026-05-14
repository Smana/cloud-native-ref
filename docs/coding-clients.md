# Connecting coding clients to the self-hosted LLM gateway

The cluster exposes an OpenAI-compatible endpoint at
`https://llm.priv.cloud.ogenki.io/v1` (Tailscale-fronted, `tag:k8s` ACL).
Any client that speaks the OpenAI chat-completions API or the
OpenAI completions API (FIM) can talk to it.

## Authentication

The Envoy AI Gateway enforces **API-key authentication** via an Envoy
Gateway `SecurityPolicy` (`infrastructure/base/envoy-ai-gateway/security-policy.yaml`).
Clients send the standard OpenAI-compatible `Authorization: Bearer <key>`
header; the gateway compares the value against the keys defined in the
AWS Secrets Manager entry at `platform/llm/api-keys` (a JSON object
keyed by client identity).

Retrieve a key for personal use:

```bash
aws secretsmanager get-secret-value \
  --secret-id platform/llm/api-keys \
  --query SecretString --output text | jq -r .openwebui_apikey
```

> Don't paste the value into your tool config file. Export it as an
> environment variable (`export OPENAI_API_KEY=$(aws secretsmanager …)`)
> and let your tool pick it up via env-var expansion. Most OpenAI-
> compatible clients (Continue, OpenCode, OpenAI SDKs) auto-detect
> `OPENAI_API_KEY` from the environment.

To onboard a new identity (e.g. a teammate or a new tooling integration),
add a new key to the SM JSON (e.g. `developer_apikey: sk-…`) and append
the corresponding entry to the gateway-side template in
`infrastructure/base/envoy-ai-gateway/api-keys-externalsecret.yaml`.

## Models exposed

`GET /v1/models` returns:

| Model id | Backed by | Purpose |
|---|---|---|
| `MoM` | semantic-router auto-routing | Default for OpenWebUI; SR classifies the prompt and picks one of the xplane-* upstreams below |
| `xplane-qwen-coder` | Qwen2.5-Coder-7B-Instruct | Code chat, agentic edits. **Function-calling supported.** |
| `xplane-qwen-coder-fim` | Qwen2.5-Coder-1.5B-Base | FIM tab-completion. **Always warm.** |
| `xplane-qwen3-8b` | Qwen3-8B | Multilingual, math, longer-context (32k) |

Pick a specific `xplane-*` model when you already know the workload —
saves the ~250-300ms semantic-router classifier round-trip. Use `MoM`
when you want auto-routing (typical for OpenWebUI users).

## OpenCode CLI

OpenCode (`github.com/sst/opencode`) speaks OpenAI-compatible APIs
natively. Edit `~/.opencode/config.toml`:

```toml
[providers.local]
type = "openai"
base_url = "https://llm.priv.cloud.ogenki.io/v1"
# OpenCode reads OPENAI_API_KEY from the environment when api_key is
# unset. Export it once: `export OPENAI_API_KEY=$(aws secretsmanager …)`.
default_model = "xplane-qwen-coder"

[default]
provider = "local"
```

Then `opencode` from any project root. The agent uses
`xplane-qwen-coder` by default; tool calls work because that model has
function-calling support.

## VSCode + Continue extension

Continue (`continue.dev`) supports a separate model per role: `chat`,
`autocomplete`, `edit`, `apply`. The chat profile and the FIM profile
need different endpoints:

`~/.continue/config.yaml`:

```yaml
models:
  - name: Qwen Coder (chat / agentic)
    provider: openai
    model: xplane-qwen-coder
    apiBase: https://llm.priv.cloud.ogenki.io/v1
    apiKey: ${env:OPENAI_API_KEY}  # pragma: allowlist secret
    roles:
      - chat
      - edit
      - apply
    defaultCompletionOptions:
      maxTokens: 2048
      temperature: 0.2

  - name: Qwen Coder FIM (autocomplete)
    provider: openai
    model: xplane-qwen-coder-fim
    apiBase: https://llm.priv.cloud.ogenki.io/v1
    apiKey: ${env:OPENAI_API_KEY}  # pragma: allowlist secret
    roles:
      - autocomplete
    template: qwen
    defaultCompletionOptions:
      maxTokens: 256
      temperature: 0.0
```

`template: qwen` tells Continue to use the Qwen FIM token format
(`<|fim_prefix|>...<|fim_suffix|>...<|fim_middle|>`). Without this,
the extension sends prompts in CodeLlama format and the model can't
parse them.

## Claude Code (deferred)

Claude Code speaks the **Anthropic API**, not the OpenAI API. To make
it talk to this gateway you need a translator (e.g.
`claude-relay-server`, `claude-bridge`) deployed as a sidecar Service
that exposes Anthropic-style endpoints and proxies to our OpenAI
gateway. Filed as a follow-up; not implemented in the initial
deployment. OpenCode covers the same agentic-CLI workflow and works
out of the box.

## OpenWebUI (already wired)

`https://chat.priv.cloud.ogenki.io` (Tailscale, `tag:k8s` ACL).

- Default model dropdown selection: `xplane-qwen3-8b` (set via the
  `DEFAULT_MODELS` env var on the OpenWebUI Deployment). SR runs on
  every request and may rewrite `body.model` based on prompt content,
  so the cascade still applies even when the user picks a specific
  model:
  - `code` → `xplane-qwen-coder`
  - `math` / `physics` → `xplane-qwen3-8b` (with `use_reasoning: true`)
  - `multilingual` → `xplane-qwen3-8b`
  - `other` → `xplane-qwen3-8b`
- To force a specific model, switch the dropdown — the response header
  `x-vsr-selected-model` will reflect what actually served the request.
- **All 4 models default to `min=1`** (always warm) per
  [SPEC-001](../docs/specs/0001-llm-platform-prometheus-autoscaling/spec.md).
  KEDA scales `1→max` on leading saturation signals (`running/max-num-seqs`
  ratio + `gpu_cache_usage_perc`); first-request latency is dominated by
  prompt-classifier overhead (~250-300ms via SR), not cold start.
  A claim with an explicit `scaling.minReplicas: 0` override accepts
  first-request failure — pre-warm via
  `kubectl scale deploy/xplane-<model> -n llm --replicas=1` before demos.

## Verifying the connection

```bash
# Smoke test — list models (works on any client)
curl -sS https://llm.priv.cloud.ogenki.io/v1/models | jq '.data[].id'

# Direct chat completion against the coder model (no SR cascade)
curl -sS -X POST https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "xplane-qwen-coder",
    "messages": [{"role":"user","content":"Write a Python function to compute fibonacci"}]
  }'

# FIM completion (Continue-style)
curl -sS -X POST https://llm.priv.cloud.ogenki.io/v1/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "xplane-qwen-coder-fim",
    "prompt": "<|fim_prefix|>def fib(n):\n    <|fim_suffix|>\n    return fib(n-1) + fib(n-2)<|fim_middle|>",
    "max_tokens": 50,
    "temperature": 0.0
  }'

# MoM cascade (OpenWebUI-style — SR classifies and rewrites the body)
curl -sS -X POST https://llm.priv.cloud.ogenki.io/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -D - \
  -d '{
    "model": "MoM",
    "messages": [{"role":"user","content":"refactor this Go function for clarity"}]
  }' | grep -i x-vsr-selected
```

## Troubleshooting

- **`401 Unauthorized` from envoy** — `Authorization` header missing or
  the value doesn't match any key in the gateway-side Secret. Verify
  `echo $OPENAI_API_KEY` is non-empty and matches one of the keys in
  `platform/llm/api-keys`. New keys take up to 1h to propagate (ESO
  refresh); force with `kubectl annotate externalsecret/ai-gateway-api-keys -n envoy-ai-gateway-system force-sync=$(date +%s) --overwrite`.
- **`404 The model 'X' does not exist`** — the model name doesn't match
  any served name. Check `GET /v1/models` and use one of the listed
  ids. If you're using `MoM` and seeing this, the SR config is wrong
  (`auto_model_name` doesn't match) — look at the SR pod logs in the
  `llm` namespace.
- **Tab-complete is slow (>1 s)** — Continue is using chat-completions
  fallback instead of FIM. Verify your config has `template: qwen` and
  `roles: [autocomplete]`. The `xplane-qwen-coder-fim` Service must
  exist (`kubectl get svc -n llm xplane-qwen-coder-fim`).
- **`Access denied` 403 from envoy** — Cilium L7 policy rejected the
  request. Either (a) the source pod doesn't have a CNP allowing
  egress to the `llm-router` Service, or (b) the destination
  InferenceService's CNP doesn't allow your client identity. For
  external clients via Tailscale Gateway this shouldn't happen; for
  in-cluster clients see `apps/base/openwebui/app.yaml` for the
  reference egress block.
