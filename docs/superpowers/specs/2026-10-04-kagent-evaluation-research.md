# Research: Can kagent replace any part of the agent factory?

**Topic**: kagent-evaluation · **Conducted**: 2026-10-04 · **Researcher**: Claude (two research
subagents, one by layer, and an adversarial verification pass)

---

SP1 rejected kagent as a harness in one line, "kagent v1 is alpha" (S7 in the
[SP1 design](2026-09-23-agent-runtime-identity-design.md)). kagent v1 has since grown a pluggable
`Harness`, sessions and a Substrate runtime, so it now overlaps most of the programme. This pass
asks whether it replaces any sub-project: SP1 runtime and identity, SP2 rooms, SP3 factory, SP4
routing, O-1 observability.

Read at:

| Ref | SHA |
|---|---|
| kagent `main` (v1 line; latest `v1.0.0-alpha7`, 2026-10-01) | `bf8afa563e4f55f2c9f9e9cb54c4efa4dd23d271` |
| kagent `v0.10.3` (latest stable, 2026-10-02, branch `release/v0.10.x`) | `8878c39ac64421cb665c8e62ecc6411dd12f2fc2` |
| kagent's Substrate fork `kagent-dev/substrate` `v0.3.0-alpha3` | `228790e92b59f0c3b3ea2e01a38fbecd92bc4d14` |

Links below use `M:` for `https://github.com/kagent-dev/kagent/blob/bf8afa563e4f55f2c9f9e9cb54c4efa4dd23d271/`
and `T:` for `https://github.com/kagent-dev/kagent/blob/8878c39ac64421cb665c8e62ecc6411dd12f2fc2/`.

## TL;DR

- **kagent replaces no sub-project.** The programme stands as designed.
- **It is two products under one name.**
  - v1 (`main`, alpha) runs only on kagent's own fork of Agent Substrate.
  - v0.10 (stable, called "legacy" by the project) runs one long-running Deployment per agent.
- **v1 inherits Substrate's model and adds gaps of its own:**
  - agents packed into shared worker pods, with no ServiceAccount or pod spec per agent;
  - runtime → controller identity sent as an unsigned header;
  - no token budgets.
- **Sessions are single-owner.** A share link acts *as the owner*, and there is one agent per
  session. Rooms stay ours.
- **Open-source kagent has no authorization**, and its controller takes the user from a header or
  query parameter. Anything that reaches it directly can act as anyone.
- **No factory features in either edition, Solo Enterprise included.**
- **Worth learning:** session checkpoint and fork *with a runtime snapshot*. It depends on
  Substrate, so it lands with the Substrate re-check, not before.

## Two products under one name

| | v0.10.3 (stable) | `main` / v1 (alpha) |
|---|---|---|
| Runtime | One `Deployment` + `Service` + config `Secret` per agent, long-running (`T:go/core/internal/controller/translator/agent/manifest_builder.go#L72-L136`) | Substrate only: the controller exits if it cannot reach Substrate's API (`M:go/core/pkg/app/app.go#L272-L280`). An agent is an `ActorTemplate`, a session is an Actor in a shared worker pod |
| Per-agent pod spec | ServiceAccount, `nodeSelector`, tolerations, `securityContext`; **no `runtimeClassName`**, no liveness probe | None, by design (`M:AGENTS.md#L17-L19`) |
| Model key | Env `SecretKeyRef` **inside the agent pod** by default (`T:go/core/internal/controller/translator/agent/adk_api_translator.go#L566-L581`); avoidable, since `apiKeySecret` is optional and a keyless gateway works | Injected at Substrate's egress gateway; the agent holds a placeholder. Static keys only |
| Privilege | Skills or code execution set `privileged: true` unless `allowPrivilegeEscalation: false` is set (`T:.../manifest_builder.go#L424-L438`, `#L508-L509`) | Worker pods add 13 capabilities incl. `SYS_ADMIN`; atelet is privileged (Substrate) |
| One-shot run | None | `ScheduledRun`: a PostgreSQL row with a 15-minute deadline and terminal states; the deadline is a cooperative A2A cancel |
| Project direction | Maintained in parallel; "legacy" (`M:AGENTS.md#L21`) | Where kagent invests; no GA date, no migration guide |

kagent added a kubernetes-sigs/agent-sandbox backend in #1640 (2026-04-09) and removed it in #2049
(`9a470b90`, 2026-06-26): "substrate is the thing we'll go with". That is the opposite of our D9.

## Feature map

| Our feature | kagent (open source) | Solo Enterprise adds | Verdict |
|---|---|---|---|
| **Sandbox** (agent-sandbox + gVisor, one pod per run, tainted spot pool, restricted PSS) | v1: gVisor actors in shared worker pods; an agent can get its own `WorkerPool` (labels, nodeSelector, tolerations), never its own ServiceAccount or pod spec. v0.10: Deployment, no `runtimeClassName` | — | Keep ours. v1 is the Substrate model already evaluated (ADR-0041) |
| **Per-run identity** (ServiceAccount per run, tokens held by the identity-proxy) | v1: no ServiceAccount; the runtime identifies itself with an unsigned header, checked against the stored session and actor but not signed, pending [substrate#1660](https://github.com/agent-substrate/substrate/issues/1660) (open). v0.10: one ServiceAccount per agent, not per run | Token exchange and on-behalf-of tokens | Keep ours |
| **GitHub credentials** (octo-sts per run and role) | Nothing for agents; git is only for fetching skills | — | Keep ours |
| **Egress** (default-deny CNP + FQDN allowlist per run) | v1: a per-actor allow-list **inferred** from models, MCP and skills (a GitHub skill source adds `github.com`); a per-agent `egress` field is in review ([#3019](https://github.com/kagent-dev/kagent/pull/3019)); DNS bypasses it; no CNP per agent. v0.10: no policy, but labels let our CNP attach | — | Keep ours. Package registries are unreachable on v1 today, and the policy sits outside Cilium |
| **Gateway and budgets** | `baseUrl` to any OpenAI-compatible gateway; no budget, no iteration limit (draft [#3020](https://github.com/kagent-dev/kagent/pull/3020) adds per-turn `budgetUSD`/`maxTurns`, Claude harness only) | — | Keep ours (ADR-0053) |
| **Harness** (OpenHands, swappable by profile) | Claude Code CLI (proprietary, run with permissions bypassed), Codex CLI (full access), kagent ADKs, BYO | — | Keep OpenHands. A BYO adapter needs kagent's private A2A gRPC and task-store client, and a Python process that survives snapshot restore, which kagent's own doc says fails ("Illegal instruction") |
| **Rooms: shared session** | One owner and one agent per session; share-link visitors act as the owner; no per-message author | Resource RBAC, multi-tenancy | Keep ours. Attribution is the core of SP2 |
| **Rooms: driver, handoff, steering** | One active task per session; busy sends rejected; cancel only | — | Keep ours |
| **Rooms: approvals** | `tool_approval` / `ask_user` A2A extension; anyone who can send can approve, recorded as the owner. v1 cannot configure per-tool MCP approval | **UNVERIFIED** whether it restricts approvers | Keep ours |
| **Rooms: replay and log** | Durable PostgreSQL history, rebuilt on read; no event cursor | Audit trails | Keep ours (gapless `seq`, C4) |
| **Rooms: fork** | Checkpoint + fork with a Substrate snapshot of the runtime | — | **Better than ours**, but only on Substrate. Our fork copies the log and starts a fresh run |
| **Human UI and SSO** | React UI; optional oauth2-proxy; `NoopAuthorizer`. The default `insecure` mode reads the user from `?user_id=` or `X-User-Id`, and `trusted-proxy` mode accepts any bearer token, so a direct caller can be anyone | OIDC group → admin/writer/reader, AccessPolicy | Keep ours |
| **Factory** (GitHub intake, PR provenance, merge gate, daily cap, stop switch, Kueue, triage) | None | None | Keep ours |
| **Observability** (per-run dashboard, metadata-only traces) | OTel GenAI attributes, prompts off by default on v1; no metrics of its own, no dashboards | ClickHouse pipeline, trace-tree UI | Keep ours. O-1 already uses `gen_ai.*` |

## Project health

- **Governance.** CNCF Sandbox since 2025-05-22; the incubation application
  [cncf/toc#1978](https://github.com/cncf/toc/issues/1978) has been open since 2025-12. 7 of 8
  maintainers are Solo.io (`kagent-dev/community` `MAINTAINERS.md` at `8b507421`).
- **Churn.** The API moved `v1alpha1` → `v1alpha2` → `v1alpha3`; the old versions were deleted from
  `main` on 2026-09-04 (#2696). Seven v1 alphas shipped in 13 days. The database schema has no
  upgrade path yet.
- **Design record.** v1's rationale is not published: plans live in a gitignored `.plans/`, and
  `design/` holds no v1 proposal.
- **Coupling.** v1 pulls in kagent's Substrate fork (40 commits ahead of upstream, 24 behind) and a
  kagent-built agentgateway as its egress router. Solo Enterprise 0.5.9 still bundles the v0.10
  line.

## Re-check

Fold kagent into the **2026-12-15** ax/Substrate re-check. Its v1 rides on Substrate, so Substrate's
triggers apply first. Pilot it only if, in addition:

- runtime → controller calls are authenticated (substrate#1660 merged and wired);
- per-agent egress destinations ship ([#3019](https://github.com/kagent-dev/kagent/pull/3019));
- open-source kagent verifies identity and authorizes actions;
- sessions record per-message authors for several participants;
- v1 reaches GA with a migration path.

## Open questions

- [ ] Does EKS 1.36 serve `PodCertificateRequest` and `ClusterTrustBundle`
      (`certificates.k8s.io/v1beta1`)? It decides whether v1 runs on aws-0 at all.
      `kubectl get --raw /apis/certificates.k8s.io`.
- [ ] Does a Python harness survive Substrate snapshot restore on x86 EKS/GKE nodes? kagent reports
      the failure on its kind setup only.
- [ ] Does Solo Enterprise restrict who may approve a tool call, and record the approver?
- [ ] Will kagent's Substrate fork be upstreamed?

## References

- kagent: [repo](https://github.com/kagent-dev/kagent), [releases](https://github.com/kagent-dev/kagent/releases),
  [#2049](https://github.com/kagent-dev/kagent/pull/2049), [#2574](https://github.com/kagent-dev/kagent/issues/2574),
  [#2583](https://github.com/kagent-dev/kagent/issues/2583)
- Solo Enterprise for kagent: [about](https://docs.solo.io/kagent/latest/about/), [OBO](https://docs.solo.io/kagent/latest/security/obo/)
- Agent Substrate: [#1660](https://github.com/agent-substrate/substrate/issues/1660); prior passes:
  [SP1 research](2026-09-23-agent-runtime-identity-research.md),
  [ecosystem re-check](2026-10-01-agent-ecosystem-recheck-research.md)
