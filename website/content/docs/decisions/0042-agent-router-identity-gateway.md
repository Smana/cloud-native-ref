---
title: Agent Router is the agents' identity gateway, with role and data class encoded in the token audience and an in-pod proxy holding the tokens
linkTitle: 0042 · Agent identity gateway
weight: 420
description: Agent runs reach models and MCP tools only through a dedicated agent-router Gateway, one listener per data class, validating the run's projected ServiceAccount token offline. Role and data class travel in the audience because Envoy Gateway matches claims exactly. An Envoy sidecar in each sandbox holds the run-long tokens (R2) and injects them, so the harness never does. agentgateway, per-route policies and a run-long harness key were rejected.
lastVerified: 2026-10-01
---

**Status**: Accepted; Option 1 superseded for the agent router by [ADR-0053]({{< relref "/docs/decisions/0053-agent-router-on-agentgateway.md" >}})

> **Superseded for the agent router, 2026-10-01.** [ADR-0053]({{< relref "/docs/decisions/0053-agent-router-on-agentgateway.md" >}})
> moves the `agent-router` Gateway to agentgateway after a passing PoC, which also verified Option 2's
> `sub`-prefix claim live. The audiences, the three listeners, the Kyverno reservation and the in-pod
> identity-proxy below still hold; Option 1's Envoy Gateway mechanism does not.

**Date**: 2026-09-26
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

An agent run must call models and read-only MCP tools under its own identity (programme D3), without
ever holding a provider key, and `internal` data must never reach a SaaS model (OD-13). Envoy Gateway
1.9.2 validates JWTs against a remote JWKS and copies claims into headers, but matches claims
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
  and API-key injection are all in the pinned Agent Router 1.1.0 / Envoy Gateway 1.9.2 schemas
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
fed by file SDS) as the only token holder. A third listener, `sts` (:8082), fronts octo-sts and accepts
exactly the four `octo-sts/<owner>/<repo>/<role>` audiences from this cluster's issuer, on both
clouds. octo-sts's trust policies can match aws-0's EKS issuer only by pattern, since it changes on
every rebuild, and that pattern admits any EKS cluster in the region; gcp-0's GKE issuer is matched
exactly (owner decision, 2026-09-26).

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
- Identity reaching MCP backends is confirmed from source: `x-ar-agent`, via the MCPRoute's
  `securityPolicy.oauth.claimToHeaders` (C5); SP2 no longer needs the fallback for this path
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

## Re-check trigger (2026-10-01)

Agent Router 1.1.0 speaks MCP **2025-06-18** only. 2025-11-25 support is requested in
[agent-router#1575](https://github.com/theagentrouter/agent-router/issues/1575), and nothing tracks
2026-07-28; today only version negotiation keeps clients and servers working. agentgateway already
supports 2026-07-28. Reopen this decision if **either**:

- an MCP server or harness on the platform drops 2025-06-18, **or**
- Agent Router has not added 2025-11-25 support by **2026-12-15**.

Option 2's "UNVERIFIED" `sub`-prefix claim is now verified from source (agentgateway v1.5.0 registers
CEL `startsWith`, and its RBAC tests match on `jwt.sub`). A time-boxed PoC replacing this Gateway
with agentgateway is running on gcp-0; its result decides whether this ADR is superseded. Envoy
Gateway citations above are corrected to 1.9.2, the `main` pin since 2026-09-30. Evidence: the
[ecosystem re-check](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-01-agent-ecosystem-recheck-research.md)
and the [gap matrix](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-01-agentgateway-gap-matrix-research.md).

---

## References

- [Agent Router v1.1 notes](https://theagentrouter.ai/release-notes/v1.1/)
- [Envoy credential_injector](https://www.envoyproxy.io/docs/envoy/latest/configuration/http/http_filters/credential_injector_filter)
- [Kubernetes projected ServiceAccount tokens](https://kubernetes.io/docs/concepts/storage/projected-volumes/)
