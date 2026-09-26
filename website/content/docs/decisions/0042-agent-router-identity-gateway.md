---
title: Agent Router is the agents' identity gateway, with role and data class encoded in the token audience and an in-pod proxy holding the tokens
linkTitle: 0042 · Agent identity gateway
weight: 420
description: Agent runs reach models and MCP tools only through a dedicated agent-router Gateway, one listener per data class, validating the run's projected ServiceAccount token offline. Role and data class travel in the audience because Envoy Gateway matches claims exactly. An Envoy sidecar in each sandbox holds the run-long tokens (R2) and injects them, so the harness never does. agentgateway, per-route policies and a run-long harness key were rejected.
lastVerified: 2026-09-26
---

**Status**: Accepted
**Date**: 2026-09-26
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

An agent run must call models and read-only MCP tools under its own identity (programme D3), without
ever holding a provider key, and `internal` data must never reach a SaaS model (OD-13). Envoy Gateway
1.9.1 validates JWTs against a remote JWKS and copies claims into headers, but matches claims
**exactly** and cannot address the nested `kubernetes.io` claim. OpenHands reads its LLM key once per
conversation, and under gVisor a rotated projected token never reaches a reader inside the pod (SP1
spike Q2), so each token lives until its run's deadline (R2, C3).

---

## Decision Drivers

- A token copied out of a sandbox must die with its run, at the run's deadline (R2)
- "`internal` never reaches Z.ai" must hold by construction, not by a rule evaluated after routing
- No provider key in namespace `agents`
- One harness-neutral localhost contract

---

## Considered Options

### Option 1: Agent Router (Envoy AI Gateway) on its own `agent-router` Gateway, one listener per class

**Pros**:
- JWT validation, `claimToHeaders`, early header removal, MCPRoute `oauth` and per-tool authorization,
  and API-key injection are all in the pinned Agent Router 1.1.0 / Envoy Gateway 1.9.1 schemas
- The listener rejects the other class's token before routing; Z.ai routes attach to `public` only

**Cons**:
- Offline validation: a copied token is valid until `exp`, the run's deadline (R2)
- EG cannot prefix-match `sub`: a Kyverno audience reservation and a data-plane CNP admitting only
  `agents` pods close that gap

### Option 2: agentgateway at the agent boundary

**Pros**:
- CEL authorization might express the `sub` prefix (UNVERIFIED); an RFC 8693 client

**Cons**:
- A second gateway product beside the one the platform runs; its distinct OSS feature is unused by
  autonomous agents (programme D11)

### Option 3: One listener, per-route SecurityPolicies

**Cons**:
- Two routes on one listener both match `x-ai-eg-model`, and a route-level policy runs only after the
  route is chosen: the class boundary would depend on filter order

### Option 4: The run's token passed as the harness's API key

**Cons**:
- The harness, which the agent drives through a shell, would hold the token, so one prompt injection
  exfiltrates it. Tokens are run-long under R2 either way; the proxy keeps them out of the agent's reach

---

## Decision Outcome

**Chosen option**: "Agent Router on a dedicated `agent-router` Gateway, one listener per class", with
audiences `agent-router.<role>.<dataClass>` and an in-pod Envoy `identity-proxy` (`credential_injector`
fed by file SDS) as the only token holder.

**Rationale**: It is the only shape where the class boundary and the key boundary are both
structural, using controllers the platform already runs.

---

## Consequences

### Positive

- Agents and humans use separate Gateways and separate provider keys (C1)
- Every harness gets the same contract: `127.0.0.1:4000` (public), `:4002` (internal), `:4001`
  (octo-sts)

### Negative

- The harness can still *use* its credential through localhost; the boundary is what the credential
  can reach, not whether the agent can call it
- Whether identity reaches MCP backends is UNVERIFIED (C5); SP2 carries the fallback
- Tokens live until the run's deadline, not 600 s (R2): under gVisor kubelet's rotation raises no
  inotify, so the file watch never reloads. A Lua filter re-reading the token per request would keep
  600 s (a re-read does see the new file) and was not taken: more proxy code for a window that only
  matters after a sandbox compromise

### Neutral

- SP4 owns the model mapping behind each listener and the budget rules on this Gateway

---

## Implementation Notes

`infrastructure/base/agent-router/`, `infrastructure/base/agent-runtime/identity-proxy-configmap.yaml`,
Kyverno `agent-audience-reservation`. Secrets through `security/base/agent-secrets/` only.

---

## References

- [Agent Router v1.1 notes](https://theagentrouter.ai/release-notes/v1.1/)
- [Envoy credential_injector](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter)
- [Kubernetes projected ServiceAccount tokens](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
