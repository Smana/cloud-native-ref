# Research: Do agentgateway, agentregistry or Agent Substrate fill a gap in the agent-factory design?

**Topic**: agent-ecosystem-recheck · **Conducted**: 2026-10-01 · **Researcher**: Claude (subagent)

A fact-check of an outside critique that proposed all three. Upstream was read with `gh api`
(release notes, CRD schemas at tag) and the projects' docs. The platform was read at
`integration/agent-factory` = `147819ff`: most repository paths below exist only on the programme
branches, not on `main`, and so are ADR-0041 to ADR-0052 (programme ADRs). Anything not confirmed is marked **UNVERIFIED**. The capability-level
comparison of agentgateway against the agent router is in the
[companion gap matrix](2026-10-01-agentgateway-gap-matrix-research.md).

## TL;DR

| Project | Verdict | Why |
|---|---|---|
| agentgateway | **Revisit at a trigger** (PoC in progress on gcp-0) | Nothing it does is both unused and needed today. Its one real edge over our pin is MCP spec currency: it supports 2026-07-28, while Agent Router 1.1.0 stops at 2025-06-18. The owner approved a time-boxed PoC on 2026-10-01 after the gap matrix found no blocker; it is running on gcp-0 |
| agentregistry | **Reject** | A Postgres-backed developer catalog for IDEs, mid-pivot: v0.4.0 and `main` removed its own Kubernetes runtime and now target kagent. Nothing in the design consumes a catalog, and packaging is already an OCI digest plus a Crossplane profile |
| Agent Substrate | **Revisit on 2026-12-15 (unchanged)** | v0.3.0 (2026-09-30) made real progress (per-actor JWT, authorization part 1, egress policy work), but none of ADR-0044's re-check triggers is met. The critique's "loses per-run identity and token limits" is mostly false under the issuer-agnostic run identity of [contract C2](2026-09-23-agent-factory-design.md) |

> **2026-10-01 outcome.** PoC GO on gcp-0; the owner selected agentgateway for agent-router, and an
> ADR superseding ADR-0042 and ADR-0050 Option 1 follows. That decision supersedes the ADR-0042
> re-check trigger proposed below (gap 1 and the agentgateway section). Result:
> [gap matrix](2026-10-01-agentgateway-gap-matrix-research.md#poc-result-2026-10-01-gcp-0).

What the research surfaced that the design does not record:

| # | Gap | Where | Smallest fix |
|---|---|---|---|
| 1 | Agent Router speaks MCP 2025-06-18 only, and no trigger tracks it. [agent-router#1575](https://github.com/theagentrouter/agent-router/issues/1575) (2025-11-25 support) has been open since 2025-11-26; nothing tracks 2026-07-28. Only version negotiation protects us today | `infrastructure/base/agent-mcp/mcproutes.yaml`; ADR-0042 | A re-check trigger on ADR-0042 (below). Optionally a smoke test running `tools/list` through the gateway with the pinned harness SDK |
| 2 | Kueue, the factory's admission and kill-switch layer, is designed but not deployed. Concurrency is capped in the factory instead (`concurrentRuns: 4`) | ADR-0048; `tooling/base/agent-factory/helm-values-configmap.yaml`; no `ClusterQueue` in the tree | State it in any "complete" claim; it lands with the factory's triage phase |
| 3 | No durable run provenance: neither `AgentRun.status` nor the room-event envelope records the harness image digest, composition revision or instruction commit. It can be rebuilt from Git plus time, but nothing stores it | [runtime-identity design](2026-09-23-agent-runtime-identity-design.md), [factory design](2026-09-23-agent-dark-factory-design.md) | One `status.harnessDigest` field (plus the composition revision), or a payload on the run-start event |
| 4 | ADR-0044 Option 4 and [rooms decision S7](2026-09-23-agent-collaboration-rooms-design.md) assume agentgateway is the only A2A path. Agent Router's `next` docs ship an A2A capability in **Preview**, on Envoy's native A2A filter; an `A2ARoute` CRD is requested in [agent-router#2070](https://github.com/theagentrouter/agent-router/issues/2070) | ADR-0044, rooms design | One line: try Agent Router's A2A filter first |
| 5 | ADR-0042 cites Envoy Gateway 1.9.1; the pin is 1.9.2 | `flux/sources/ocirepo-envoy-gateway.yaml` | Correct the cite |

Known residual, not new: Agent Router 1.1.0 lets `resources/*` and `prompts/*` through without
tool authorization. It is mitigated because the three MCP servers expose only static docs there.
The gap matrix found, from source, that agentgateway's MCP authorization covers both.

## agentgateway

**Upstream**: v1.5.0 GA (2026-08-27, `fe67324`); v1.6.0-alpha.2 (2026-09-22); `main` = `dd7a4b3`
(2026-09-30). Apache-2.0. Roughly monthly minors, **each with breaking changes**: 1.5.0 changed
token-count semantics, JWT `iss`/`aud` enforcement, policy merge and ReferenceGrant for delegation
([v1.5.0 notes](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0)).

### The critique's claims

| Claim | Verdict | Evidence |
|---|---|---|
| Rust data plane for AI-native protocols | **True** | `crates/agentgateway/`; README |
| Donated to the Linux Foundation, August 2025 | **True** | [LF press, 2025-08-25](https://www.linuxfoundation.org/press/linux-foundation-welcomes-agentgateway-project-to-accelerate-ai-agent-adoption-while-maintaining-security-observability-and-governance). Moved into the Agentic AI Foundation (AAIF) in 2026 ([blog](https://agentgateway.dev/blog/2026-06-04-agentgateway-joins-aaif/)) |
| "The CNCF-native way to serve MCP" | **False** | Not a CNCF project. Agent Router (ex-Envoy AI Gateway) also left CNCF for AAIF on 2026-09-10 ([blog](https://theagentrouter.ai/blog/envoy-ai-gateway-is-now-agent-router/)), so the two are foundation peers and neutrality does not separate them |
| Integrates with Kubernetes Gateway API | **True**, through its **own controller**, not an Envoy Gateway plugin | `controller/`, CRDs `AgentgatewayBackend/Policy/Model/Parameters`, built on Gateway API v1.6.1 (we pin v1.6.2). Adopting it adds a **third** Gateway API implementation beside Cilium and Envoy Gateway |
| MCP gateway federates tools | **True** | `AgentgatewayBackend.spec.mcp.targets`. Agent Router does the same with `MCPRoute.backendRefs` |
| Transport translation "OpenAPI or HTTP/SSE to stdio" | **Partly**: the direction is backwards, and standalone only | stdio servers are exposed **as** HTTP and OpenAPI **as** MCP tools. The Kubernetes CRD admits only `SSE` and `StreamableHTTP` targets. Every MCP server we run is already Streamable HTTP |
| A2A gateway with capability discovery and modality negotiation | **Partly** | Discovery and modality are A2A protocol features (the Agent Card). The gateway proxies, rewrites agent-card URLs and applies policy ([docs](https://agentgateway.dev/docs/kubernetes/latest/documentation/agent/a2a/)) |
| "Network-level governance for supervisor/sub-agent patterns, replacing RWX PVC sharing" | **False** for this platform | No shared-PVC collaboration exists; the only `ReadWriteMany` volumes hold LLM weights. Agents never talk to each other: sequential runs hand over through the room log (ADR-0044 Option 1) |

### Against what we run (Agent Router 1.1.0 on Envoy Gateway 1.9.2)

| Capability | Agent Router 1.1.0 | agentgateway 1.5.0 |
|---|---|---|
| Per-tool allow/deny per caller | MCPRoute `authorization` on `aud`, deny by default; `tools/list` filtered | `AgentgatewayPolicy` CEL on `jwt.*` and `mcp.tool.name`; `tools/list` filtered ([docs](https://agentgateway.dev/docs/kubernetes/latest/documentation/mcp/tool-access/)) |
| Upstream API-key injection | `securityPolicy.apiKey` per backend | Backend auth, including a per-request minted JWT |
| No caller bearer forwarded to MCP servers | Calls are re-originated (CI gate) | Validated JWT stripped by default; passthrough is opt-in (verified from source in the gap matrix) |
| `resources/*`, `prompts/*` authorization | No | Yes, from source (gap matrix); the docs cover tools only |
| **MCP spec version** | **2025-06-18 only** | **2026-07-28**, negotiating the intersection across federated targets ([spec-compat](https://agentgateway.dev/docs/kubernetes/latest/documentation/mcp/spec-compatibility/)) |
| RFC 8693 token exchange | No | Client in OSS; STS minting is Solo Enterprise |
| A2A | Preview, on Envoy's A2A filter; `A2ARoute` requested (#2070) | Proxy, agent-card rewrite, policy |
| LLM routing and token budgets on one gateway | Yes | Yes; budgets are standalone mode with SQLite/Postgres only |

**What changed upstream since the 2026-09-23 decisions**: agentgateway shipped no new stable
release; its 1.6 work centres on Substrate egress credential injection (agentgateway#3411).
Agent Router renamed itself and moved to AAIF; no release since v1.1.0 (2026-08-21). The only
fact that sharpens the comparison is MCP spec currency.

**Cost of adoption**: a third Gateway API controller and four more CRD sets for the schema
catalog; re-implementing ADR-0042's three listeners, the audience encoding and the CI gates;
monthly breaking minors; budgets that need a database.

**Re-check trigger** (proposed for ADR-0042; superseded on 2026-10-01, see the outcome above): reopen if **either** an MCP server or harness on the
platform stops negotiating 2025-06-18, **or** Agent Router has not shipped 2025-11-25 support by
**2026-12-15**. For A2A, try Agent Router's filter first.

## agentregistry

**Upstream**: v0.4.0 (2026-08-03); `main` = `4be0a2a` (2026-09-29). Apache-2.0. A CNCF Sandbox
application is drafted; acceptance is **UNVERIFIED**.

| Claim | Verdict | Evidence |
|---|---|---|
| Central registry (UI, `arctl`, REST) for MCP servers, agents, prompts | **True**, plus skills, models, plugins | README; `openapi.yaml` |
| Publishes, versions **and deploys** | **Partly, and shrinking** | `main` removed the built-in Kubernetes runtime (#619, "fundamentally flawed"), the local deployment adapter (#612) and source-based agents and servers (#684). Deployment now goes through a kagent adapter (#655) |
| Breaks GitOps: a stateful database is the source of truth | **True** | Postgres is mandatory; 16 SQL migrations; `arctl apply -f` takes Kubernetes-shaped YAML but writes to the database. No CRDs. Git is a source only for plugin and skill content (#653) |
| "Borrow the packaging idea; stick to OCI and Crossplane packages" | **True, and already done** | `AgentRun.spec.harness` is a profile the composition maps to an image digest; compositions ship as a version-pinned Crossplane package; role instructions are in-repo files behind the merge gate |

It was never evaluated by name, and the model makes it moot: agents do not **discover** tools (a
role's tool set is fixed by MCPRoute authorization on the token audience), and humans do not pick
agents from a catalog (the factory derives role, harness and model). Its pivot to "catalog with
pluggable runtimes, kagent first" moves it further from our stack.

**Re-check trigger**: only if the platform starts serving human IDE clients a curated MCP catalog.
Even then, the MCP registry's `server.json` served statically from Git is the GitOps-native option.

## Agent Substrate

**Upstream**: **v0.3.0, 2026-09-30** (`ccecc78`); `main` = `7317e08`, 44 commits past the
[2026-09-27 re-check](2026-09-27-agent-substrate-recheck-research.md). google/ax `main` moved 2
commits, including `ac23328`, which replaces its Redis Streams queue and controller: another
architectural change.

| Claim | Verdict | Evidence |
|---|---|---|
| Multiplexes sandboxes onto pre-warmed pods at ~10x density | **Upstream's claim**; independently **UNVERIFIED** | README ("~250 stateful actors across just 8 physical pods") |
| Bypasses Kubernetes scheduling | **Partly** | Workers are pods placed by kube-scheduler; actors are placed by Substrate's own scheduler, so **Kueue cannot admit them**. It replaces our admission layer, not kube-scheduler |
| Loses per-run IAM | **Mostly false** for this design | Actors get their own JWT with a configurable issuer (#1834); v0.3.0 makes a lifetime mandatory and aligns `sub` with the SPIFFE ID (#1902). Contract C2 is issuer-agnostic, so actor JWTs become one more allowlisted issuer. What breaks is a memory fork freezing the parent's credentials into the child. Whether actor JWTs can carry our per-role audiences is **UNVERIFIED** |
| Loses per-run token limits | **False** | Budgets are enforced at the agent router on the token's `sub`/`aud`, independent of the runtime |
| Loses per-pod Cilium policies | **True** | Actors share worker pods with a network namespace each (#1836, #1689); Cilium sees only the worker. Per-actor egress goes through Substrate's agentgateway-based egress gateway. That breaks the constitution's per-workload default-deny CNP |
| Prefer pods + Kueue + Karpenter | **True in direction, imprecise in fact** | Already the plan (ADR-0041, ADR-0048), but gcp-0 uses node auto-provisioning and ComputeClasses, not Karpenter, and Kueue is not deployed yet |

### Re-check triggers, re-scored

| Trigger (ADR-0044) | 2026-09-27 | 2026-10-01 | Evidence |
|---|---|---|---|
| EKS ships 1.37 | Not met | **Not met** | Newest on standard support is 1.36 ([EKS versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)) |
| Substrate closes #1898 (ClusterTrustBundle v1) | Open | **Open** | `gh issue view 1898` |
| Lifts the no-spot rule | In docs | **Still in docs** | `tools/setup-gcp/README.md` at `7317e08`. #1528 is the merged PR that *added* the warning, so the trigger should name the README rule |
| Fixes #1657 (one CPU model per WorkerPool) | Open | **Open** | — |
| Private registries (#432, #868) | Open | **Open** | — |
| ax closes #376 and #363 | Open | **Open**. #376 reproduced on `main` 09-27, with a correction that the control plane is not reachable from every sandbox by default | `gh issue view 376 -R google/ax` |
| Two minors without an architectural rewrite | Not met | **1 of 2** for Substrate (v0.3.0 declares no breaking change); not met for ax (`ac23328`) | release notes |

Progress worth recording, none of it a trigger: runtime authorization part 1 for Atespace CRUD
(#1702), though `docs/authentication.md` still says authorization is not implemented; an actor
usage event (#1881; whether it carries tokens is **UNVERIFIED**); a GCP Secret Manager credential
provider (#1991).

**Gap it would fill**: parking and fork density. No demand at ≤ 4 concurrent runs.
**Cost**: per-run CNP, Kueue reach and spot workers; its own Postgres; a partly authorized API;
one CPU model per pool.

**Re-check**: keep **2026-12-15**. Reword the no-spot trigger to "removes the no-spot rule from
`tools/setup-gcp/README.md`", and add "authorization enforced beyond Atespace CRUD".

### 2026-10-04 re-check: ax and Substrate claims against code

Read at `google/ax@ac23328` (no commit since 2026-09-27) and `agent-substrate/substrate@16b863a`
(59 commits past v0.3.0). The verdict stands; three earlier statements were imprecise.

| Claim | Verdict | Evidence |
|---|---|---|
| ax's control plane has no authentication or authorization | **Holds** | [ax#376](https://github.com/google/ax/issues/376) open, no fix merged. "Critical" is the reporter's account of the Google OSS VRP triage. `cmd/ax-server/main.go` has outbound (ax → Substrate) auth flags only |
| ax runs an unvalidated branch through `git fetch` | **Holds** | [ax#363](https://github.com/google/ax/issues/363) open; [`setup.go#L224-L227`](https://github.com/google/ax/blob/ac23328/internal/workspace/setup.go#L224-L227) passes `branch` positionally, no `--` |
| ax supports Gemini only and puts the key in every task | **Holds** | [`client.go#L486-L495`](https://github.com/google/ax/blob/ac23328/internal/model/client.go#L486-L495); [`reconciler.go#L153-L154`](https://github.com/google/ax/blob/ac23328/internal/controller/reconciler.go#L153-L154) |
| ax v0.3.0 left no harness | **Corrected** | [`dc4f36c`](https://github.com/google/ax/commit/dc4f36c) removed `internal/controller/eventlog/` and `python/antigravity/harness_server.py`, but `cmd/ax-task-runner/antigravity_bootstrap.py` now starts Google's Antigravity agent when a goal and `GEMINI_API_KEY` are set. ax has a harness; it is Gemini-only. [`ac23328`](https://github.com/google/ax/commit/ac23328) is unreleased (latest v0.3.1, 2026-09-25) |
| Substrate actors share worker pods | **Holds** | [`glossary.md#L48-L50`](https://github.com/agent-substrate/substrate/blob/16b863a/docs/glossary.md#L48-L50); `--max-actors` defaults to 1000 ([`ateom-gvisor/main.go#L70`](https://github.com/agent-substrate/substrate/blob/16b863a/cmd/ateom-gvisor/main.go#L70)). Actors share a hostname and interior IP ([`observability.md#L427`](https://github.com/agent-substrate/substrate/blob/16b863a/docs/observability.md#L427)) |
| Substrate has no per-actor network policy | **Corrected** | Each actor has a default-deny `EgressPolicy`, shipped in v0.3.0 ([`ateapi.proto#L422-L457`](https://github.com/agent-substrate/substrate/blob/16b863a/pkg/proto/ateapipb/ateapi.proto#L422-L457)), enforced at the egress gateway on a per-actor mTLS certificate. It is not a Kubernetes or Cilium policy, covers egress only, and port 53 bypasses it. Constitution §3.1 still holds only at the worker |
| Substrate has no authorization | **Corrected** | The docs still say so ([`authentication.md#L28`](https://github.com/agent-substrate/substrate/blob/16b863a/docs/authentication.md#L28)), but v0.3.0 ships OpenFGA enforcement behind `--experimental-enable-authz`, off by default ([`ateapi/main.go#L84`](https://github.com/agent-substrate/substrate/blob/16b863a/cmd/ateapi/main.go#L84)); access-policy APIs followed on `main` ([#1965](https://github.com/agent-substrate/substrate/pull/1965)) |
| Substrate forbids spot workers | **Reworded** | A documented warning, not enforced: an actor still awake 30 minutes after its worker is deleted is `CRASHED`, terminally ([`setup-gcp/README.md#L100-L106`](https://github.com/agent-substrate/substrate/blob/16b863a/tools/setup-gcp/README.md#L100-L106)) |
| Substrate documents only GKE | **Holds** | kind (local dev) and a GKE quickstart marked "Development" ([`README.md#L86-L147`](https://github.com/agent-substrate/substrate/blob/16b863a/README.md#L86-L147)); no EKS guide. WebSocket egress is still blocked (`docs/egress-traffic.md`) |

Triggers that moved, both on `main` and **unreleased**:

| Trigger | 2026-10-01 | 2026-10-04 | Evidence |
|---|---|---|---|
| Substrate closes #1898 (ClusterTrustBundle v1) | Open | **Closed 2026-10-02** | #1924 prefers v1 and falls back to v1beta1. PodCertificateRequest is still required; whether EKS serves it is **UNVERIFIED** |
| Private registries (#432, #868) | Open | **#432 closed** (kubelet credential provider, #917, #2108); #868 open | `gh issue view 432 868 -R agent-substrate/substrate` |

**Re-check**: keep **2026-12-15**. ax's blockers are untouched, and Substrate's remaining gaps are
the shared-pod model against per-workload CNP and ServiceAccount, experimental authorization, the
no-spot warning and no EKS path.

## References

- agentgateway: [releases](https://github.com/agentgateway/agentgateway/releases), [v1.5.0](https://github.com/agentgateway/agentgateway/releases/tag/v1.5.0), [joins AAIF](https://agentgateway.dev/blog/2026-06-04-agentgateway-joins-aaif/), [MCP tool access](https://agentgateway.dev/docs/kubernetes/latest/documentation/mcp/tool-access/), [MCP spec compatibility](https://agentgateway.dev/docs/kubernetes/latest/documentation/mcp/spec-compatibility/), [A2A](https://agentgateway.dev/docs/kubernetes/latest/documentation/agent/a2a/)
- Agent Router: [rename and AAIF](https://theagentrouter.ai/blog/envoy-ai-gateway-is-now-agent-router/), [MCP capability](https://theagentrouter.ai/docs/next/capabilities/mcp/), [A2A capability](https://theagentrouter.ai/docs/next/capabilities/a2a/), [releases](https://github.com/theagentrouter/agent-router/releases), [#1575](https://github.com/theagentrouter/agent-router/issues/1575), [#2070](https://github.com/theagentrouter/agent-router/issues/2070)
- agentregistry: [repo](https://github.com/agentregistry-dev/agentregistry), PRs #612, #619, #653, #655, #684
- Substrate: [v0.3.0](https://github.com/agent-substrate/substrate/releases/tag/v0.3.0); README, `docs/authentication.md`, `tools/setup-gcp/README.md` at `7317e08`; issues #1898, #1657, #432, #868; PRs #1528, #1702, #1836, #1689, #1902
- EKS: [Kubernetes versions on standard support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)
