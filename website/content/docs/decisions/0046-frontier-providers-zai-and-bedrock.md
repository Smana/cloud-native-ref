---
title: Frontier models through Z.ai and keyless Anthropic per cloud (Bedrock on aws-0, Vertex on gcp-0)
linkTitle: 0046 · Frontier providers
weight: 460
description: Frontier models reach the platform through two providers chosen by data class — Z.ai GLM for public data, with its key held by the gateways, and Anthropic's Claude for internal data with no key at all — Amazon Bedrock EU via EKS Pod Identity on aws-0, Vertex AI via Workload Identity on gcp-0. A native Anthropic API key and aggregators such as OpenRouter were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted; the internal-data provider superseded by [ADR-0054]({{< relref "/docs/decisions/0054-agent-model-providers-anthropic-direct.md" >}})

> **Superseded for internal data, 2026-10-01.** [ADR-0054]({{< relref "/docs/decisions/0054-agent-model-providers-anthropic-direct.md" >}})
> sends internal data to the Anthropic API directly, with a key in OpenBao, on both clouds. Bedrock
> and Vertex below become optional per-cloud backends. The Z.ai choice for public data stands.

**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP4 — LLM complexity routing](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md)

---

## Context

Agents need a capable model with zero GPUs, and hard chat prompts need one above the local 7–8B fleet.
Until now the only frontier caller was RunLore, holding a Z.ai key in its own pod. The agent factory
adds a data-class rule: `public` agent work may go to a SaaS model, while `internal` data (cluster
reads, RunLore findings) may reach only EU-resident Anthropic or self-hosted models.

## Decision Drivers

- No provider key in any workload pod; keys live only where the gateways read them.
- Internal data stays in EU regions.
- Both client formats: OpenAI (OpenWebUI, OpenCode) and Anthropic (Claude Code).
- Cost: GLM-5.2 is $1.40 / $4.40 per 1M tokens (GLM-5.3, which replaced it on 2026-09-27, lists at the same price); Claude Opus 5.5 is $4 / $20.

## Considered Options

### Option 1: Z.ai GLM + Anthropic on Bedrock (Pod Identity) / Vertex (Workload Identity)

**Pros**:
- Bedrock needs no key: the data plane's ServiceAccount assumes a role scoped to the `eu.anthropic.*`
  inference profiles.
- Agent Router translates both OpenAI and Anthropic input to Bedrock's `AWSAnthropic` schema.

**Cons**:
- EU geo profiles route across EU regions (Frankfurt, Paris, Stockholm, Milan, Spain, Ireland), not
  Paris alone.
- Bedrock is billed through AWS Marketplace, and model access needs a one-time subscription.

### Option 2: A native Anthropic API key

**Pros**:
- The simplest setup, and it gets new models first.

**Cons**:
- Agent Router v1.1.0 has **no** OpenAI → native-Anthropic translator (PR #2127 is open), so
  OpenAI-format clients cannot reach it.
- A long-lived key to hold and rotate.

### Option 3: OpenRouter or another aggregator

**Pros**:
- One key and many models.

**Cons**:
- A third party sees every prompt, and data residency is the aggregator's choice.
- It adds a hop and a markup.

### Option 4: Self-hosted only

**Pros**:
- No data leaves the cluster.

**Cons**:
- The fleet's 7–8B models are not agent-capable. It also ties agents to GPU capacity, which the
  programme exists to avoid.

### Option 5: One Anthropic provider for both clouds (Vertex-only)

**Pros**:
- Unified provider: aws-0 and gcp-0 both call Vertex.

**Cons**:
- aws-0's internal data leaves AWS via cross-cloud identity federation (EKS token exchange to GCP).
  This breaks ADR-0007's rule that each cloud uses its own native service.

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: It is the only option that serves both client formats with no key in a workload pod,
and keeps internal data in the EU. Z.ai serves public work at roughly a third of Claude Opus 5.5's
list input price.

## Consequences

### Positive

- Separate keys per Gateway split both spend and blast radius: the platform key under
  `platform/llm/zai`, and the agents' own key, read only through their `agents-secrets` store
  (since 2026-09-29 at `zai` on the dedicated `agents` kv-v2 mount, as for ADR-0043's App key).
  Until SP4 PR 6 (not built) moves the platform key to `platform/llm/zai`, it is read from
  `platform/runlore/credentials`, where it already lives, so no bootstrap has to copy it.
- Bedrock credentials rotate themselves and cannot be exfiltrated as a string.

### Negative

- Z.ai's processing and retention terms are unverified (research, open question 10). That is why
  only `public` data may reach it.
- A Bedrock Marketplace subscription is an owner action per account.

### Neutral

- gcp-0 reaches the same Claude models through Vertex with Workload Identity (`GCPAnthropic`), in a
  follow-up.

---

## Implementation Notes

| Step | Scope | State |
|---|---|---|
| SP4 PR 1 | The platform Z.ai backend and `tier-frontier` on `ai-gateway` | Built |
| SP4 PR 2 | The Bedrock EPIs, `claude-*` on `ai-gateway`, and the agent tiers on `agent-router` | Not built |
| Follow-up | Vertex (`GCPAnthropic`) on gcp-0 | Not started |

So the keyless Anthropic path does not exist yet on either cloud. Agents reach one model,
`agent-default` → Z.ai GLM-5.3, on the `public` listener; the `internal` listener has no model
backend, so `internal` work has no model to call until PR 2 or the Vertex follow-up lands.

---

## References

- [Agent Router v1.1.0 translators](https://github.com/theagentrouter/agent-router/blob/v1.1.0/internal/endpointspec/endpointspec.go)
- [Bedrock model cards](https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html)
- [Z.ai pricing](https://docs.z.ai/guides/overview/pricing)
