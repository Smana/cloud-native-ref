---
title: Internal agent work calls the Anthropic API directly; public work stays on Z.ai, with OpenRouter optional
linkTitle: 0054 · Agent model providers
weight: 540
description: The agent router's internal listener calls the Anthropic API directly through agentgateway's native Anthropic provider, with a key held in OpenBao that runs never see. The same model serves both clouds. Public work stays on Z.ai; OpenRouter is an optional public-only backend. Bedrock and Vertex become optional per-cloud backends. Supersedes ADR-0046's choice of keyless Claude through Bedrock or Vertex for internal data.
lastVerified: 2026-10-01
---

**Status**: Accepted
**Date**: 2026-10-01
**Deciders**: Smana (Platform Owner)
**Related Spec**: [Agent router on agentgateway — design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-01-agent-router-agentgateway-design.md)
**Supersedes**: [ADR-0046]({{< relref "/docs/decisions/0046-frontier-providers-zai-and-bedrock.md" >}})'s provider for internal data (keyless Claude through Bedrock on aws-0 and Vertex on gcp-0). Its Z.ai choice for public data stands.

---

## Context

ADR-0046 sent internal data to Claude through each cloud's own service: Bedrock with EKS Pod
Identity on aws-0, Vertex with Workload Identity on gcp-0. Neither has been built. The two clouds
would serve different model IDs with different availability. The aws-0 half cannot be proven while
aws-0 is destroyed, and gcp-0, the primary cloud (ADR-0052), had only an unstarted "Vertex
follow-up". The internal listener therefore has no model on either cluster today.

[ADR-0053]({{< relref "/docs/decisions/0053-agent-router-on-agentgateway.md" >}}) moves the agent
router to agentgateway, whose `AgentgatewayBackend.spec.ai.provider` offers `anthropic`, `openai`,
`bedrock`, `vertexai` and others as native providers at v1.5.0. Choosing a provider is now a backend
object, not a platform build. ADR-0046 rejected a native Anthropic key (its Option 2) because keyless
access was available on both clouds; that premise no longer holds, and this record reverses the
rejection for internal data.

---

## Decision Drivers

- `internal` data reaches only a provider whose data terms we accept, never a SaaS aggregator
- The same model on both clouds, provable on gcp-0 now
- No provider key in namespace `agents`: the gateway holds it
- Cloud-agnostic: no per-cloud identity plumbing for the default path

---

## Considered Options

### Option 1: Bedrock per cloud (ADR-0046 on aws-0)

**Pros**:
- Keyless (EKS Pod Identity); data stays in the AWS account; EU inference profiles

**Cons**:
- aws-0 only; unprovable while aws-0 is destroyed
- An IAM role, an EPI, a Pod Identity egress rule and a Marketplace subscription per cluster
- Model IDs and availability differ from the other cloud

### Option 2: Vertex per cloud (ADR-0046 on gcp-0)

**Pros**:
- Keyless (Workload Identity); data stays in the GCP project

**Cons**:
- gcp-0 only; a different model catalogue and quota process from Bedrock
- Never started

### Option 3: Anthropic API directly (chosen)

**Pros**:
- One backend, one model ID set, both clouds; provable on gcp-0 at once
- Native agentgateway provider (`spec.ai.provider.anthropic`), Messages format end to end
- Anthropic is the only data processor for internal prompts

**Cons**:
- A static API key in OpenBao, not keyless
- Data leaves the cloud account; residency follows Anthropic's terms, not a region we pick

### Option 4: OpenRouter

**Pros**:
- Model breadth behind one OpenAI-compatible key; useful for experiments

**Cons**:
- A second data processor, and we do not control which upstream serves a request
- Unacceptable for internal data; acceptable only for public work

---

## Decision Outcome

**Chosen option**: "Option 3" for the `internal` listener, with Option 4 as an optional, off-by-default
backend on `public`. `public` stays on Z.ai (ADR-0046). Bedrock and Vertex remain available as
optional per-cloud backends for teams whose data must stay inside their cloud account; nothing
depends on them.

| Listener | Default backend | Optional |
|---|---|---|
| `public` | Z.ai (`api.z.ai`, agents' own key) | OpenRouter (`openrouter.ai`, its own key), off by default |
| `internal` | Anthropic API (`api.anthropic.com`, key from OpenBao `agents` mount, secret `anthropic`) | Bedrock (aws), Vertex (gcp), per team |

**Rationale**: It is the only option that gives internal work a model on both clouds now, with one
backend and one processor.

---

## Consequences

### Positive

- `internal` runs get a model on gcp-0 immediately; the same `claude-*` IDs serve both clouds
- One backend object replaces two per-cloud identity stacks; aws-0 no longer blocks anything
- Budgets can name the provider: one token bucket per provider beside B1–B2

### Negative

- **A static key**, not keyless: stored at OpenBao `agents/anthropic` (`api_key`), synced by
  External Secrets into `agent-system`, injected by the gateway. A leak of that Secret is a
  spendable credential until revoked; rotation is a `bao kv put` and an ExternalSecret refresh
- **Data terms (default, the owner may revisit)**: the standard Anthropic commercial API terms,
  under which API inputs and outputs are not used to train models. Anthropic keeps API data for a
  limited period under its retention policy. A zero-data-retention agreement removes that retention;
  it is a documented option, **not a precondition** for sending internal data
- Internal prompts leave the cloud account. Teams that need them to stay inside it use the optional
  Bedrock or Vertex backend

### Neutral

- OpenRouter is documented and gated: public listener only, off by default, its own key and budget
- ADR-0046's Z.ai decision, keys and price rules for public data are unchanged
- SP4's `claude-*` names on `ai-gateway` follow this record when built, with a platform key of their
  own (C1: humans and agents never share a provider key)

---

## Implementation Notes

The [agentgateway plan](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/plans/2026-10-01-agent-router-agentgateway-plan.md)
phase I adds the Anthropic backend, the internal tiers and per-provider budgets, proven on gcp-0. Its
appendix holds the optional OpenRouter, Bedrock and Vertex backends.

---

## References

- [agentgateway v1.5.0 CRDs](https://github.com/agentgateway/agentgateway/tree/v1.5.0/controller/install/helm/agentgateway-crds/templates): `AgentgatewayBackend.spec.ai.provider.anthropic`
- [Anthropic API](https://docs.anthropic.com/en/api/overview), [commercial terms](https://www.anthropic.com/legal/commercial-terms), [privacy center: API data retention](https://privacy.anthropic.com/)
- [OpenRouter](https://openrouter.ai/docs)
