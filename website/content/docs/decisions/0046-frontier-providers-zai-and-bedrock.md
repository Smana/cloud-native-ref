---
title: Frontier models through Z.ai and Anthropic on Bedrock, behind the gateways
linkTitle: 0046 · Frontier providers
weight: 460
description: Frontier models reach the platform through two providers chosen by data class — Z.ai GLM for public data, with its key held by the gateways, and Anthropic's Claude on Amazon Bedrock EU for internal data, with no key at all (EKS Pod Identity). A native Anthropic API key and aggregators such as OpenRouter were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
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
- Cost: GLM-5.2 is $1.40 / $4.40 per 1M tokens; Claude Opus 5.5 is $4 / $20.

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

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: It is the only option that serves both client formats with no key in a workload pod,
and keeps internal data in the EU. Z.ai serves public work at roughly a third of Claude Opus 5.5's
list input price.

## Consequences

### Positive

- Separate keys per Gateway (the platform key under `platform/llm/zai`, the agents' key under
  `platform/agents/zai`) split both spend and blast radius.
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

- SP4 PR 1: the platform Z.ai backend and `tier-frontier` on `ai-gateway`.
- SP4 PR 2: the Bedrock EPIs, `claude-*` on `ai-gateway`, and the agent tiers on `agent-router`.

---

## References

- [Agent Router v1.1.0 translators](https://github.com/theagentrouter/agent-router/blob/v1.1.0/internal/endpointspec/endpointspec.go)
- [Bedrock model cards](https://docs.aws.amazon.com/bedrock/latest/userguide/model-cards.html)
- [Z.ai pricing](https://docs.z.ai/guides/overview/pricing)
