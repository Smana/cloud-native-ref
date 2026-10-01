---
title: The agent router runs on agentgateway; ai-gateway stays on Envoy Gateway
linkTitle: 0053 · Agent router on agentgateway
weight: 530
description: The agents' Gateway (LLM, MCP and the octo-sts token-exchange listener) moves from Envoy Gateway and Agent Router 1.1.0 to agentgateway, keeping its name, listeners and audiences. Budgets run on our own envoyproxy/ratelimit. The human-facing ai-gateway stays on Envoy Gateway. Supersedes ADR-0042 Option 1 and ADR-0050 Option 1 for the agent router only.
lastVerified: 2026-10-01
---

**Status**: Accepted
**Date**: 2026-10-01
**Deciders**: Smana (Platform Owner)
**Related Spec**: [Agent router on agentgateway — design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-01-agent-router-agentgateway-design.md)
**Supersedes, for the agent router only**: [ADR-0042]({{< relref "/docs/decisions/0042-agent-router-identity-gateway.md" >}}) Option 1 (and its rejection of Option 2), [ADR-0050]({{< relref "/docs/decisions/0050-token-budgets-envoy-gateway-rate-limit.md" >}}) Option 1

---

## Context

ADR-0042 put the agent boundary on Agent Router 1.1.0 over Envoy Gateway 1.9.2. Three things
changed by 2026-10-01:

- **Envoy Gateway cannot express the boundary's core rule.** It matches claims exactly, so the `sub`
  prefix check ("only ServiceAccounts in `agents`") is compensated by a Kyverno audience reservation
  and a data-plane CNP.
- **Agent Router has stalled on MCP.** It speaks spec 2025-06-18 only
  ([agent-router#1575](https://github.com/theagentrouter/agent-router/issues/1575) open since
  2025-11), does not authorize `resources/*` or `prompts/*`, and has had no release since 1.1.0
  (2026-08-21). Its advisory **GHSA-76mr-h444-pcqq** (MCP denial of service, published 2026-09-26/29
  with six others) lists `vulnerable <=1.1.0, patched 1.1.0`, a self-contradictory range: our pin
  may be affected, and no newer version exists to move to.
- **A PoC passed.** agentgateway v1.5.0 ran beside agent-router on gcp-0 and passed all eight live
  checks, the four gating ones included: the `sub` prefix refused a correct-audience token from the
  wrong namespace (403), forged identity headers were replaced, MCP tools, prompts and resources were
  filtered per role with no bearer reaching a server, and token budgets counted in shadow through
  `envoyproxy/ratelimit`
  ([PoC result](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-01-agentgateway-gap-matrix-research.md#poc-result-2026-10-01-gcp-0)).

SP4 PR 2, which would add Bedrock and budgets B1–B2 to the agent router, is unbuilt: switching now
costs the least it ever will.

---

## Decision Drivers

- The class and identity boundary enforced by the gateway itself, not by compensating controls
- MCP authorization over tools, prompts and resources, and a current MCP spec
- No unpatched advisory on the agent boundary
- No custom code in the data path; budgets stay token-costed, shared and shadow-first (ADR-0050's drivers)
- The harness contract (`127.0.0.1:4000/4002/4001`) and the token audiences do not change

---

## Considered Options

### Option 1: Stay on Agent Router 1.1.0

**Pros**:
- Built, gated (A1–A7) and running; no migration
- One gateway product for humans and agents

**Cons**:
- The `sub` prefix stays inexpressible; the boundary keeps relying on Kyverno and a CNP
- MCP stays at 2025-06-18 with `resources/*` and `prompts/*` unauthorized
- GHSA-76mr-h444-pcqq may apply to the pin, with nothing newer to move to
- MCPRoutes duplicate the listener's issuer and audiences by hand (618 lines)

### Option 2: agentgateway beside Agent Router, for MCP only

**Pros**:
- Fixes MCP authorization and spec currency
- Leaves the LLM path untouched

**Cons**:
- Two gateway products on every run's path, with per-path upstreams on each identity-proxy port
- The `sub` prefix gap stays on the LLM and `sts` listeners, and every Envoy-specific gate stays
- The worst cost-to-gain ratio of the four

### Option 3: Replace the agent router with agentgateway (chosen)

**Pros**:
- CEL authorization expresses `jwt.sub.startsWith("system:serviceaccount:agents:")`; proven live (P1)
- JWT validation runs before every other filter, so the `/v1/models`-before-auth bug class cannot occur
- The validated JWT is stripped by default; only the `sts` listener opts in to forwarding it
- MCP authorization covers tools, prompts and resources, at spec 2026-07-28 with negotiation
- One listener policy covers LLM and MCP routes: no hand-kept copy
- Proxies idle at 6–8 MiB against 69–84 MiB for Envoy plus ext_proc

**Cons**:
- v1alpha1 APIs with monthly breaking minors
- Budgets need a rate-limit server we run: agentgateway bundles none
- A third Gateway API controller, and a second policy language beside `ai-gateway`'s
- Metric names, proxy labels and MCP tool names change (`<target>_<tool>`)

### Option 4: Wait

Re-check at ADR-0042's trigger (2026-12-15, or an MCP server dropping 2025-06-18).

**Pros**:
- No work now; Agent Router may ship a release

**Cons**:
- SP4 PR 2 would be built on Envoy first and then ported
- The advisory and the boundary gap stay open meanwhile

---

## Decision Outcome

**Chosen option**: "Option 3", for the agent router only. Gateway `agent-router`, class
`agentgateway`, in a new namespace `agent-gateway`, keeps its three listeners and its audiences.
Budgets B1–B2 run on `envoyproxy/ratelimit` with its own Valkey `KVStore`, token-costed, shared and
in shadow. `ai-gateway` stays on Envoy Gateway and Agent Router: its Semantic Router insertion order
and InferencePool wiring work today and gain nothing from a move.

**Rationale**: It is the only option that closes the boundary gap, the MCP gaps and the advisory
together, and the PoC proved each on the cluster.

---

## Consequences

### Positive

- ADR-0042's boundary holds by construction: the gateway refuses a token minted outside `agents`
- Leaving the agent router removes the platform's only MCPRoutes, so GHSA-76mr-h444-pcqq no longer
  reaches the platform once the Envoy agent-router is deleted
- Three gated bug classes disappear by construction (`/v1/models` answered before auth, appended
  identity headers, the hand-kept MCP issuer copy); the rest are re-expressed on agentgateway kinds,
  against schemas pinned to the installed release

### Negative

- We operate the rate-limit server Envoy Gateway ran for us. It fails open, as before
- **A stream cut before completion is never charged** (budget cost is evaluated at completion).
  An explicit drain (`shutdown: {min: 120, max: 660}`) stops rollouts and drains from cutting
  streams; a client abort or a proxy crash still spends uncounted tokens. Envoy Gateway charges at
  end of stream too, so this is likely parity
- MCP tool names change from `<backend>__<tool>` to `<target>_<tool>`; the room-bridge classifier
  and the probes change with them
- A denied MCP item answers `Unknown tool`, not a permission error
- Releases must be read before each minor bump; the pin moves only at a minor's first patch release

### Neutral

- ADR-0042's audiences, listeners, Kyverno reservation and in-pod identity-proxy are unchanged; only
  the proxy's upstream FQDN moves
- ADR-0050's budget model (who, how much, shadow first, enforcement in SP4 PR 7) is unchanged; only
  the mechanism moves
- Metrics are relabelled at scrape to the `gen_ai_*` names `ai-gateway` still emits

---

## Implementation Notes

[The plan](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/plans/2026-10-01-agent-router-agentgateway-plan.md)
runs agentgateway beside the Envoy agent-router, switches new runs by changing the identity-proxy's
upstream, and deletes the Envoy agent-router only after the live gates pass. SP4 PR 2's agent half
(tiers, Bedrock on aws-0, B1–B2) is built on agentgateway; its `ai-gateway` half is unchanged.

---

## References

- [agentgateway v1.5.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0) and its [security advisories](https://github.com/agentgateway/agentgateway/security/advisories)
- [Agent Router security advisories](https://github.com/envoyproxy/ai-gateway/security/advisories), including GHSA-76mr-h444-pcqq
- [envoyproxy/ratelimit](https://github.com/envoyproxy/ratelimit)
- [Gateway API v1.6 conformance report for agentgateway v1.5.0](https://github.com/kubernetes-sigs/gateway-api/blob/main/conformance/reports/v1.6/agentgateway-agentgateway/v1.5.0-report.yaml)
