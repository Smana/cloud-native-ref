---
title: Token budgets on Envoy Gateway's global rate limit, costed from response metadata
linkTitle: 0050 · Token budgets
weight: 500
description: Per-run, per-fleet, per-human and per-client daily token budgets are Envoy Gateway global rate-limit rules, charged after each response with the token count Agent Router writes into metadata, and stored in a Valkey KVStore. Agent Router's QuotaPolicy, a custom ext_proc and LiteLLM budgets were rejected.
lastVerified: 2026-09-25
---

**Status**: Accepted
**Date**: 2026-09-25
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP4 — LLM complexity routing](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md)

---

## Context

Frontier models cost real money, and a looping agent is a denial-of-wallet. Every principal needs a
daily token cap: a run, the agent fleet, each human, each API-key client, plus a kill switch on
frontier spend. They must be enforced at the gateways, the only path to a provider.

## Decision Drivers

- Enforced synchronously in the data path, with no custom data-path code.
- Keyed on identity headers set from a verified credential.
- One bucket per principal across every route the principal can reach.

## Considered Options

### Option 1: Envoy Gateway global rate limit, cost from response metadata, Valkey

**Pros**:
- Envoy Gateway's own global rate-limit API. Agent Router's `llmRequestCosts` writes the token count
  into metadata, which the rule charges after the response.
- `shared: true` gives one bucket across routes, and `shadowMode` gives a measured dry run.

**Cons**:
- Charged after the response, so an admitted stream can overshoot by one response.
- Windows are fixed UTC days, not sliding.

### Option 2: Agent Router `QuotaPolicy`

**Pros**:
- Purpose-built for token quotas.

**Cons**:
- Partly unimplemented: `ServiceQuota` is not wired.
- In its only mode (Shared), a request passes if **any** matching bucket has room, so a per-principal
  cap never binds while a default bucket has headroom.

### Option 3: A custom ext_proc

**Pros**:
- Exact per-run caps with any logic.

**Cons**:
- Custom code in the data path of every request, and a new SPOF.

### Option 4: LiteLLM budgets

**Pros**:
- Mature budget features.

**Cons**:
- A second proxy in front of or behind Agent Router, duplicating routing, auth and keys.

## Decision Outcome

**Chosen option**: "Option 1"

**Rationale**: It enforces in the data path with no custom code, and `shared` plus `shadowMode`
make it both correct and safe to roll out.

## Consequences

### Positive

- A breach answers `429` before any provider token is spent on the next request.
- Shadow counters measure every rule for a week before enforcement.

### Negative

- The exact per-run cap (`spec.budget.maxTokens`) cannot live at the gateway, because a
  ServiceAccount token carries only `sub`. The gateway holds a 5M ceiling, and SP3's run meter revokes
  a run at its own cap.
- A store outage admits traffic (`failClosed: false`).
- Envoy Gateway accepts one Gateway-level `BackendTrafficPolicy` per Gateway, so all of a Gateway's
  budgets live in one object.

### Neutral

- Every rule must set `shared: true`. A render gate (`scripts/ci/flux-schema/assert-ai-gateway.py`)
  fails the build otherwise.

---

## Implementation Notes

- SP4 PR 1: the rate limit, the `KVStore`, and B3–B5 on `ai-gateway`, all in shadow.
- SP4 PR 2: B1–B2 on `agent-router`, in shadow.
- SP4 PR 7: enforcement.

---

## References

- [Agent Router usage-based rate limiting](https://github.com/theagentrouter/agent-router/blob/v1.1.0/site/docs/capabilities/traffic/usage-based-ratelimiting.md)
- [Envoy Gateway global rate limit](https://gateway.envoyproxy.io/docs/tasks/traffic/global-rate-limit/)
