---
title: Coding Clients
weight: 10
description: Connecting OpenCode, Continue, and OpenWebUI to the self-hosted LLM gateway — authentication, model IDs, and the failure modes their errors actually mean.
lastVerified: 2026-08-27
---

The cluster exposes an OpenAI-compatible endpoint at
`https://llm.priv.aws.ogenki.io/v1` (Tailscale-fronted, `tag:k8s` ACL — see
[Private Access]({{< relref "/docs/platform/networking/private-access.md" >}})).
Any client that speaks the OpenAI chat-completions API, or the OpenAI
completions API for FIM, can talk to it — once both
[opt-in gates]({{< relref "/docs/platform/ai-platform/_index.md#turning-it-on" >}})
are released.

## Authentication

The Envoy AI Gateway enforces API-key authentication via an Envoy Gateway
`SecurityPolicy` (`infrastructure/base/envoy-ai-gateway/security-policy.yaml`).
Clients send the standard `Authorization: Bearer <key>` header; the gateway
compares the value against the keys defined in the AWS Secrets Manager entry
`platform-llm-api-keys` (a JSON object keyed by client identity).

Retrieve a key for personal use:

```bash
aws secretsmanager get-secret-value \
  --secret-id platform-llm-api-keys \
  --query SecretString --output text | jq -r .openwebui_apikey
```

Don't paste the value into a tool config file — export it as an environment
variable and let the tool pick it up via env-var expansion:

```bash
export OPENAI_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id platform-llm-api-keys \
  --query SecretString --output text | jq -r .openwebui_apikey)
```

Most OpenAI-compatible clients (Continue, OpenCode, the OpenAI SDKs)
auto-detect `OPENAI_API_KEY` from the environment. To onboard a new identity
(a teammate, a new tooling integration), add a key to the Secrets Manager
JSON and append the matching entry to the gateway-side template in
`infrastructure/base/envoy-ai-gateway/api-keys-externalsecret.yaml`.

## Models exposed

`GET /v1/models` returns:

| Model ID | Backed by | Purpose |
|---|---|---|
| `MoM` | Semantic Router auto-routing | Default for OpenWebUI; classifies the prompt and picks one of the `xplane-*` models below |
| `xplane-qwen-coder` | Qwen2.5-Coder-7B-Instruct | Code chat, agentic edits, function-calling. Serves a 10% canary onto `xplane-qwen-coder-sql-dpo` |
| `xplane-qwen-coder-fim` | Qwen2.5-Coder-1.5B | FIM tab-completion |
| `xplane-qwen3-8b` | Qwen3-8B | Multilingual, math, longer-context (32k) |
| `xplane-llamaguard3-1b` | Llama-Guard-3-1B | Listed, but in no `MoM` decision rule — reachable only by name |
| `xplane-qwen-coder-sql-dpo` | LoRA adapter on `xplane-qwen-coder` | Naming it explicitly always gets 100% of the adapter |
| `xplane-qwen-coder-securecode` | LoRA adapter on `xplane-qwen-coder` | Same |

Pick a specific `xplane-*` model when the workload is already known — it
saves the ~250–300 ms Semantic Router classifier round-trip. Use `MoM` for
auto-routing, the typical OpenWebUI case.

## OpenCode CLI

OpenCode speaks OpenAI-compatible APIs natively. Edit
`~/.opencode/config.toml`:

```toml
[providers.local]
type = "openai"
base_url = "https://llm.priv.aws.ogenki.io/v1"
# OpenCode reads OPENAI_API_KEY from the environment when api_key is unset.
default_model = "xplane-qwen-coder"

[default]
provider = "local"
```

Then run `opencode` from any project root — the agent uses
`xplane-qwen-coder` by default, and tool calls work because that model has
function-calling support.

## VSCode + Continue extension

Continue supports a separate model per role: `chat`, `autocomplete`, `edit`,
`apply`. The chat profile and the FIM profile need different model IDs in
`~/.continue/config.yaml`:

```yaml
models:
  - name: Qwen Coder (chat / agentic)
    provider: openai
    model: xplane-qwen-coder
    apiBase: https://llm.priv.aws.ogenki.io/v1
    apiKey: ${env:OPENAI_API_KEY}
    roles: [chat, edit, apply]
    defaultCompletionOptions:
      maxTokens: 2048
      temperature: 0.2

  - name: Qwen Coder FIM (autocomplete)
    provider: openai
    model: xplane-qwen-coder-fim
    apiBase: https://llm.priv.aws.ogenki.io/v1
    apiKey: ${env:OPENAI_API_KEY}
    roles: [autocomplete]
    template: qwen
    defaultCompletionOptions:
      maxTokens: 256
      temperature: 0.0
```

`template: qwen` tells Continue to use the Qwen FIM token format
(`<|fim_prefix|>...<|fim_suffix|>...<|fim_middle|>`). Without it the
extension sends CodeLlama-format prompts and the model can't parse them.

## Claude Code (not implemented)

Claude Code speaks the Anthropic API, not the OpenAI API. Pointing it at this
gateway needs a translator sidecar exposing Anthropic-style endpoints and
proxying to the OpenAI gateway — filed as an open item on the
[roadmap]({{< relref "/docs/platform/ai-platform/roadmap.md" >}}), not
implemented today. OpenCode covers the same agentic-CLI workflow and works
out of the box.

## OpenWebUI

`https://chat.priv.aws.ogenki.io` (Tailscale, `tag:k8s` ACL). Default model
dropdown selection is `xplane-qwen3-8b`. The Semantic Router's `ext_proc`
filter sits in the chain for every request but only rewrites `body.model`
when the client sent `MoM` (or the literal `auto`) — naming a model
explicitly is honoured as-is. The response header `x-vsr-selected-model`
reflects what actually served the request.

All four models default to `minReplicas: 1` (always warm); KEDA scales
`1→max` on the three leading saturation signals described in
[Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/autoscaling-and-gpu.md" >}}).
On `MoM`, first-request latency is dominated by the ~250–300 ms classifier
round-trip rather than cold start; on a directly-named model there is no
classifier cost at all.

## Verifying the connection

```bash
# Smoke test — list models (works on any client)
curl -sS https://llm.priv.aws.ogenki.io/v1/models | jq '.data[].id'

# Direct chat completion against the coder model (no Semantic Router hop)
curl -sS -X POST https://llm.priv.aws.ogenki.io/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "xplane-qwen-coder",
    "messages": [{"role":"user","content":"Write a Python function to compute fibonacci"}]
  }'

# FIM completion (Continue-style)
curl -sS -X POST https://llm.priv.aws.ogenki.io/v1/completions \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "xplane-qwen-coder-fim",
    "prompt": "<|fim_prefix|>def fib(n):\n    <|fim_suffix|>\n    return fib(n-1) + fib(n-2)<|fim_middle|>",
    "max_tokens": 50,
    "temperature": 0.0
  }'
```

## Troubleshooting

- **`401 Unauthorized`** — the `Authorization` header is missing, or its
  value doesn't match any key in `platform-llm-api-keys`. Verify
  `echo $OPENAI_API_KEY` is non-empty. New keys take up to 1h to propagate
  (External Secrets refresh); force it with
  `kubectl annotate externalsecret/ai-gateway-api-keys -n envoy-ai-gateway-system force-sync=$(date +%s) --overwrite`.
- **`404 The model 'X' does not exist`** — the model name doesn't match any
  served ID. Check `GET /v1/models`. If it happens on `MoM`, the Semantic
  Router config is wrong — check the router pod logs in the `llm` namespace.
- **Tab-complete is slow (>1s)** — Continue is falling back to chat
  completions instead of FIM. Verify the config has `template: qwen` and
  `roles: [autocomplete]`, and that the `xplane-qwen-coder-fim` Service
  exists (`kubectl get svc -n llm xplane-qwen-coder-fim`).
- **`403 Access denied` from Envoy** — a Cilium L7 policy rejected the
  request. Either the source pod lacks a `CiliumNetworkPolicy` egress rule
  to the AI Gateway data plane, or the destination `InferenceService`'s
  policy doesn't allow the client's identity — see the network-policy
  checklist in [Policies]({{< relref "/docs/platform/security/policies.md" >}}).
