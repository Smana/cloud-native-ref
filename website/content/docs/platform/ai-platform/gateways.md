---
title: Gateways
weight: 30
description: "Two gateways, one per kind of caller: ai-gateway for humans and coding clients, the agent gateway for agent runs — identity, routing, and what they share."
lastVerified: 2026-10-01
aliases:
  - /docs/platform/ai-platform/gateway-and-routing/
---

Every model call on this platform crosses one of two gateways, chosen by who is calling. Both speak
the OpenAI API; they differ in how they know the caller and in what they let it do. What runs
today, and the planned move to agentgateway, is on the
[status page]({{< relref "/docs/platform/ai-platform/status.md#agent-gateway" >}}).

| | `ai-gateway` | Agent gateway |
|---|---|---|
| **Callers** | Humans and coding clients: OpenCode, Continue, OpenWebUI, the nightly Promptfoo eval | Agent runs, through each run's identity-proxy sidecar |
| **Identity** | An API key per client, from AWS Secrets Manager | A projected token per run (JWT), verified on every call |
| **Model choice** | Named by the client, or picked from the prompt by the Semantic Router (`model: MoM`) | An alias, mapped statically to one backend; nothing selects per request |
| **Also carries** | — | MCP tool calls, the room tools, and the token exchange (`sts`) with octo-sts |
| **Software** | Envoy Gateway + Envoy AI Gateway (Agent Router) `1.1.0` | Agent Router `1.1.0` on Envoy Gateway; [agentgateway](https://agentgateway.dev) selected to replace it |

![The two gateways side by side. Top: humans and coding clients reach ai-gateway over the tailnet with an API key; the Semantic Router may pick the model, and the request lands on a vLLM model in the serving fleet. Bottom: an agent run's identity-proxy sidecar attaches the run's own token; the agent gateway verifies it, meters the run's tokens and routes the model alias to a frontier provider (Z.ai GLM, Claude), the MCP tools, or octo-sts for a GitHub token. Both gateways write access logs and gen_ai metrics to the Victoria stack](/images/diagrams/ai-platform-2.svg)

*Source: [`docs/architecture/ai-platform.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/ai-platform.drawio), page 2.*

## `ai-gateway`: humans and coding clients

The platform speaks the OpenAI API. A client points at one endpoint, names a
model — or asks the platform to choose one — and never learns which pod
answered.

### Sending a request

```bash
# What's available
curl -sS https://llm.priv.aws.ogenki.io/v1/models \
  -H "Authorization: Bearer $LLM_API_KEY" | jq '.data[].id'

# Name a model explicitly — skips classification entirely
curl -sS https://llm.priv.aws.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "xplane-qwen-coder",
        "messages": [{"role": "user", "content": "Write a Go worker pool."}]
      }'

# Let the Semantic Router choose from the prompt
curl -sS https://llm.priv.aws.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
        "model": "MoM",
        "messages": [{"role": "user", "content": "Write a Go worker pool."}]
      }'
```

The two calls reach the same pod. The difference is roughly **250–300 ms** of
classification on the `MoM` path — worth it when the client cannot know which
model suits the prompt, wasted when it can. See
[Coding Clients]({{< relref "/docs/platform/ai-platform/coding-clients.md" >}})
for which client pins which model, and why.

### The request path

The [hop-by-hop request path](/images/diagrams/llm-platform-1.svg) shows each stage below in
one picture.

**Ingress.** External clients arrive over Tailscale at the Cilium Gateway
`platform-tailscale-general` and are forwarded to the Envoy AI Gateway data
plane Service. In-cluster clients — OpenWebUI, the nightly Promptfoo eval —
address that Service directly. Nothing is reachable from the public internet;
see [Private access]({{< relref "/docs/platform/networking/private-access.md" >}}).

**Authentication.** A `SecurityPolicy` (`apiKeyAuth`) targets the Gateway, so
every route inherits it rather than each declaring its own. Keys come from AWS
Secrets Manager through External Secrets, and the gateway strips the
`Authorization` header before forwarding — vLLM never sees a credential.

**Prompt classification (`ext_proc`, filter index 0).** The Semantic Router is
wired in as an Envoy `ext_proc` gRPC filter, inserted **ahead of** the AI
Gateway's own extproc by an `EnvoyPatchPolicy` — a raw xDS JSONPatch. The
ordering is not optional and an `EnvoyExtensionPolicy` cannot express it,
because that API can only *append* filters. The router rewrites `body.model`
only when the client sent `model: MoM` (or the literal `auto`); an explicit
`xplane-*` name passes through untouched.

**Routing.** The AI Gateway extproc derives the `x-ai-eg-model` header from the
(possibly rewritten) body and emits `gen_ai_*` telemetry. An `AIGatewayRoute`
matches that header and forwards through an `AIServiceBackend` → `Backend` →
the model's Service on port 8000.

Not every claim routes this way yet: three of the four still use a hand-written route, listed
under [known gaps]({{< relref "/docs/platform/ai-platform/status.md#known-gaps" >}}).

### Semantic routing — `model: MoM`

Sending `model: MoM` lets the Semantic Router pick from the prompt. Its
decision list, highest priority first
(`infrastructure/base/vllm-semantic-router/helmrelease.yaml`):

| Priority | Decision | Target |
|---|---|---|
| 110 | code + reasoning | `xplane-qwen-coder` (`use_reasoning: true`) |
| 100 | code | `xplane-qwen-coder` |
| 90 | reasoning (math / physics) | `xplane-qwen3-8b` (`use_reasoning: true`) |
| 80 | multilingual | `xplane-qwen3-8b` |
| 50 | general (the default) | `xplane-qwen3-8b` |

{{< callout type="warning" >}}
`xplane-llamaguard3-1b` and the two LoRA adapters on `xplane-qwen-coder`
appear in **no** rule above. They hold serving capacity and are reachable only
by naming them directly. The router's own in-pod `prompt_guard` classifier
blocks jailbreak attempts, but that is a filter, not a routing decision —
there is no automatic guardrail dispatch (see
[known gaps]({{< relref "/docs/platform/ai-platform/status.md#known-gaps" >}})).
{{< /callout >}}

### LoRA canaries

`xplane-qwen-coder` carries two LoRA adapters, each addressable as a model name
of its own, and sends 10% of its traffic to one of them:

```yaml
  gateway:
    enabled: true
    canaries:
      - adapter: xplane-qwen-coder-sql-dpo
        weightPercent: 10
```

The adapter name is matched **verbatim** against `loraAdapters[].name` — it is
not derived from the base model's name, so a typo produces a route to nothing
rather than a validation error.

Canaries are mutually exclusive with the Gateway API Inference Extension's
endpoint picker. See the
[roadmap]({{< relref "/docs/platform/ai-platform/status.md#serving-roadmap" >}}) for where the
endpoint picker stands and what turning it on would take.

### Frontier models and token budgets

`tier-frontier` is served by GLM-5.3 through Z.ai with the **platform** key, which only the gateway
holds. It needs no GPU, so it answers with `llm-platform` suspended, once the `ai-gateway`
umbrella is resumed (it is suspended by default).

```bash
LLM=https://llm.priv.gcp.ogenki.io   # gcp-0; on aws-0, https://llm.priv.aws.ogenki.io
curl -s "$LLM/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_API_KEY" -H "Content-Type: application/json" \
  -d '{"model": "tier-frontier", "messages": [{"role": "user", "content": "Say hi"}]}'
```

The gateway strips `x-ar-agent`, `x-ar-human` and `x-ai-gateway-client-id` from every request before
authentication runs, so a client-forged value never survives to be charged. Today only
`x-ai-gateway-client-id` is then set — from the API key that matched. `x-ar-agent` exists only on
the separate `agent-router` Gateway; `x-ar-human` arrives with `ai-gateway`'s `oidc` listener. A
client cannot choose whose budget it spends.

Daily token budgets per API-key client (5M), per human (10M) and on all frontier spend (20M) are
counted in **shadow mode**: nothing is rejected yet
([ADR-0050]({{< relref "/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md" >}})).

## The agent gateway: agent runs

Every call an agent makes, to a model, a tool or the token exchange, goes through this gateway
under the run's own identity. The harness never sees that token: the run's identity-proxy sidecar
attaches it (see [Agent runtime]({{< relref "/docs/platform/ai-platform/agents/runtime.md" >}})).

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Gateway | [Agent Router](https://theagentrouter.ai) 1.1.0 (Envoy AI Gateway) on [Envoy Gateway](https://gateway.envoyproxy.io) | Verifies each run's token (JWT), attributes and meters every request to its run, routes the model alias to a provider. Per-run and fleet token budgets, and routing by tier | One gateway for models, tools and token exchange, with per-run identity in every access-log line |
| Models | Z.ai GLM-5.3 for `public` runs; Anthropic Claude for `internal` runs, through the Anthropic API (Bedrock or Vertex optional per cloud; ADR-0054, accepted on the programme branches) | The providers the router sends model calls to. Agents ask for an alias, never for a provider | Swapping or adding a provider changes the router, not the agents |
| Tool servers | [MCP](https://modelcontextprotocol.io) servers for Flux Operator, VictoriaMetrics and VictoriaLogs, read-only, and the room-broker's `room_*` tools | `public` runs get documentation tools only; cluster, metric and log reads are for `internal` runs. The room tools are routed per role | Agents investigate with the data humans use, under the same identity checks |

The token-exchange listener names each repository's audiences, at most eight per listener; adding
a repository is described on the [agents overview]({{< relref "/docs/platform/ai-platform/agents/_index.md#one-repository-at-first" >}}).

*Decided 2026-10-01:* [agentgateway](https://agentgateway.dev) was selected after its proof of
concept on `gcp-0` to replace Agent Router as the agents' gateway (models, MCP and the `sts`
listener). An ADR superseding programme ADR-0042 and ADR-0050's Option 1 (on the programme
branches, not yet on main) for the agent router follows. The `ai-gateway` stays on Envoy Gateway
and Agent Router.

## What the two share, and what they keep apart

From the [model routing and budgets design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md)
(SP4):

| Concern | Decision | Why |
|---|---|---|
| Semantic Router | On `ai-gateway` only; agents use their own Gateway | The router can be neither a single point of failure nor a prompt reader for agents |
| Agent model choice | Every agent alias maps to one backend: no weights, canaries or fallback | Nothing re-routes a trajectory mid-run; escalation is a new run at the next tier |
| Backends | One set per gateway, each with its own provider key | Revoking the agents' key never breaks chat or RunLore, and provider spend splits by key |
| Budgets | Token budgets at both gateways, in token units, through one global rate limit backed by Valkey | One mechanism for every principal; the factory still revokes a run at its exact cap |
