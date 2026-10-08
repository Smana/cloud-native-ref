# Research: Does anything in google/ax or Agent Substrate change SP2 (rooms) or SP3 (dark factory), one day after SP1 rejected them as the runtime?

**Topic**: agent-substrate-recheck
**Conducted**: 2026-09-27
**Researcher**: Claude (spec-research subagent)

---

Scope. The [SP1 research](2026-09-23-agent-runtime-identity-research.md#later-evaluation-agent-substrate-and-googleax-2026-09-26)
rejected ax and Substrate as the **runtime** on 2026-09-26. It asked for a re-check "at SP2 planning or on 2026-12-15,
whichever comes first". This pass does two things. It scores those triggers against upstream today. It also asks a
question SP1 did not: does either project replace or de-risk a component that **SP2 or SP3** owns (room log, parking,
fork, orchestrator, admission, kill switch)?

Upstream was read at `google/ax@d0bc38b`: `gh api repos/google/ax/compare/d0bc38b...main` returns `identical`. Substrate
was read at `agent-substrate/substrate@ed6d2a1`, 2 commits after SP1's `c7b5469`. Anything not confirmed is marked
**UNVERIFIED**.

> **2026-10-01 note.** The triggers were re-scored after Substrate v0.3.0 in the
> [ecosystem re-check](2026-10-01-agent-ecosystem-recheck-research.md): still none met. That pass also corrects the no-spot trigger, which
> should name the rule in Substrate's `tools/setup-gcp/README.md`, not #1528 (the PR that added it).

> **2026-10-04 note.** Finding 3 described v0.2.0. v0.3.0 can enforce OpenFGA authorization behind
> `--experimental-enable-authz`, off by default. Finding 9's #1898 closed on 2026-10-02 (v1
> ClusterTrustBundle on `main`, unreleased). See the
> [2026-10-04 re-check](2026-10-01-agent-ecosystem-recheck-research.md#2026-10-04-re-check-ax-and-substrate-claims-against-code).

## TL;DR

- **No re-check trigger is met; the SP1 verdict stands.** ax `main` has not moved. ax#376 (unauthenticated control
  plane, rated critical by Google's OSS VRP) and ax#363 (RCE) are open with 0 comments. Substrate's two new commits are
  a snapshot-restore refactor (`1d7ca8c`) and an agentgateway image bump (`ed6d2a1`).
- **Nothing replaces an SP2 component.** ax v0.3.0 deleted its durable event log. `WatchTask` streams only status and
  conditions. Substrate emits actor lifecycle events over OTLP. Neither has sequencing, multi-client replay,
  per-message identity or approvals, so C4 and ADR-0044 are unaffected.
- **Nothing replaces an SP3 component.** An ax `Task` is one sandbox, closer to SP1's `AgentRun` than to SP3's `Task`.
  It has no triggers, GitHub state, teams, budgets or approvals; budgets and approval policies are roadmap items. The
  control plane "does not currently read the command's exit status". Moving to Substrate would **remove** SP3 levers:
  Kueue cannot admit actors, which are not pods.
- **Substrate is ahead only on parking and fork** (SP2 §5 and §6, SP1 O2). Suspend frees the worker, and
  `CreateActor.sourceTag` restores a new actor from a published `Tag`. Waking a parked actor, though, goes through
  ingress (atenet-router) or a `ResumeActor` call on an API with no authorization, which collides with C4's push-only
  rule and SP2 T12. A fork restored from memory also freezes the parent's in-process credentials into the child, which
  collides with per-run identity (C2/C3).
- **Options for the design author:** keep the r5 hooks (issuer-agnostic C2, HTTPS bridge), keep 2026-12-15, and make
  the EKS trigger concrete (see open questions).

## Standard stack

| Component | Pick | Version | Source |
|---|---|---|---|
| google/ax | Watched, not adopted | v0.3.1 (2026-09-25); `main` = `d0bc38b`, 6 commits after v0.3.1, unchanged since SP1's read | `gh api repos/google/ax/releases`, `compare` |
| Agent Substrate | Watched, not adopted | v0.2.0 (2026-09-25): "contains **breaking changes** to the API and the wire protocol"; `main` = `ed6d2a1` | [v0.2.0 notes](https://github.com/agent-substrate/substrate/releases/tag/v0.2.0) |
| Room log (SP2) | Unchanged: CNPG `SQLInstance` + Valkey `KVStore` (ADR-0044) | — | SP2 design S8 |
| Parked runs (SP2 §6) | Unchanged: a parked run keeps its sandbox; `operatingMode: Suspended` + PVC deferred | agent-sandbox v1.0.3 | SP1 design O2 |
| Orchestrator (SP3) | Unchanged: `agent-factory` + Kueue (ADR-0048) | Kueue v0.19.5 | SP3 design S5 |

**SP1's re-check triggers, scored 2026-09-27**

| Trigger (SP1 research) | Status | Evidence |
|---|---|---|
| ax closes #376 and #363 and stops putting provider keys in sandboxes | **Not met** | Both open, 0 comments (last updated 09-23 and 09-22). `docs/runner.md` still lists `GEMINI_API_KEY` in the task container env |
| Substrate documents an EKS profile with v1 ClusterTrustBundle, ECR pulls and a spot story | **Not met; partial progress** | Progress in v0.2.0: PodCertificateRequest v1 with v1beta1 fallback (#1829); an S3 backend in `cmd/atelet/main.go` (`case "s3"`, L229–240; GCS stays the default); tolerations (#1874). Still open: ClusterTrustBundle callers are v1beta1-only ([#1898](https://github.com/agent-substrate/substrate/issues/1898)); private registries "like EKS" (#432) and ImagePullSecrets (#868). v0.2.0 adds a warning that worker pools "must not auto-upgrade or use spot nodes" (#1528). The only cloud installer is `tools/setup-gcp` |
| Two minor releases ship without an architectural rewrite | **Not met** | ax: the v0.3.0 rewrite (`dc4f36c`, −19,988 lines), then only the v0.3.1 patch. Substrate v0.2.0 breaks the API and the wire protocol |
| `Suspended` + PVC proves too lossy for rooms | **Not evaluable** | SP2 is not implemented; SP1 O2 is deferred |

## SP2 and SP3 component map (options, not decisions)

| Component (owner doc) | ax today | Substrate today | Fit |
|---|---|---|---|
| Room log: sequenced, replayable, multi-client (SP2 §2, §4; C4) | None. v0.3.0 deleted the event log. `WatchTask` "emits status and condition transitions" (`DESIGN.md`) | Actor lifecycle events over OTLP (#1658); no transcript | No |
| Harness event source for the bridge (SP2 §3) | The runner serves `/healthz`, `/readyz` and metadata; no event stream (`docs/runner.md`) | — | No; the OpenHands adapter stays |
| Parked run awaiting approval, TTL 4 h (SP2 §6; SP1 O2) | `SuspendTask`/`ResumeTask`: `/workspace` is snapshotted, and resume sees "the same files but a new process tree" (`docs/runner.md`). The same semantics as `Suspended` + PVC | `SuspendActor` frees the worker; memory and filesystem restore. Wake is triggered by an inbound request through atenet-router, with a 5 s park budget (`docs/request-parking.md`) | Partial: better density, but the wake path conflicts with C4 |
| Fork with harness memory (SP2 §5; currently a non-goal) | Roadmap: "Stateful Task Branching" | `Tag` + `CreateActor.sourceTag` (`docs/api-guide.md` §4). "Actor Forking/Cloning" is still under Coming Soon in `docs/roadmap.md`. Tagging a live run's snapshot end to end is **UNVERIFIED** | Partial: the primitive exists, with identity bleed (pitfall 1) |
| Task lifecycle against GitHub (SP3 §4) | A `Task` is one sandbox and immutable (`CreateTask` only, #398). No triggers, GitHub, teams or exit status. Budgets and approval policies are roadmap §1 | — | No: a different layer (≈ `AgentRun`) |
| Admission and concurrency (SP3 §4, §6.2: 4 concurrent runs) | Redis Streams work queue | `WorkerPool` size; "no free workers available" → 503 after the park budget | Partial: replaces Kueue and loses `HoldAndDrain` |
| Kill switch (SP3 §6.1) | `ax delete` | `DeleteActor` on an API with no authorization | Partial: the Kueue layer loses reach; the Gateway and GitHub layers are unaffected |
| Run meter and budgets (SP3 §4, C5) | None (roadmap) | Per-actor usage events (#1206, #1559); whether they carry tokens is **UNVERIFIED** | No: gateway metrics stay the source |
| Merge gate (SP3 §5) | — | — | Unaffected by any runtime |

## Local patterns worth reusing

- `docs/superpowers/specs/2026-09-23-agent-runtime-identity-research.md` (§Later evaluation): the evaluation and
  triggers this file extends.
- `docs/superpowers/specs/2026-09-23-agent-factory-design.md`:
  - r5 note (L139–147), C2 issuer-agnostic validation (L197–203), C4 HTTPS bridge (L288–293): the hooks that keep a
    Substrate backend a composition change rather than a contract change.
  - ADR table L424 (0041 carries the rejection). The 0044 and 0048 rows are where an SP2/SP3 mention would go.
- `docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md`: the push-only bridge (S3, C4); "A parked run
  spends no tokens but keeps its sandbox" (§6); T12 broker compromise; "harness memory on fork" listed as a non-goal.
- `docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md`: the Kueue role (§4) and the Kueue kill-switch layer
  (§6.1); concurrent-run cap 4 (§6.2).
- `docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`: O2 (suspension deferred, needs a PVC) and R7
  (a spot-deleted pod ends its run `Failed`, observed live on 2026-09-27).
- `infrastructure/base/karpenter-nodepools/*.yaml`: spot-first capacity with mixed instance categories. This collides
  with Substrate's no-spot rule and its one-CPU-model-per-pool constraint.
- `opentofu/aws/eks/init/variables.tf`: `kubernetes_version` default `1.36`.

## Don't hand-roll

- **Parking with files preserved**: agent-sandbox `operatingMode: Suspended` + a PVC workspace (SP1 O2) gives the same
  semantics ax exposes. Building a checkpoint layer is unnecessary.
- **Fork with memory**: not ours to build. The ecosystem paths are Substrate `Tag` + `sourceTag` and ax "Stateful Task
  Branching"; SP2's brief-based fork stays until one of them matures.
- **Per-actor egress policy**, if Substrate is ever adopted: its egress gateway enforces `EgressPolicy` (#1545) and
  ships a credential injector (#1360). Layering Cilium FQDN rules on actors would not work (pitfall 7).

## Common pitfalls

1. **Memory snapshots freeze in-process values.** An env var "would be frozen at the snapshot-source actor's values,
   since it lives in the checkpointed process memory" (`docs/api-guide.md` L209). OpenHands reads `LLM.api_key` once
   (SP1 pitfall 6), so a child restored from a parent's memory carries the parent's token and session key. Substrate's
   own guidance is that rotating identity data "must be re-read at time of use".
2. **Waking is ingress-shaped.** Resume is triggered by a request through atenet-router (`ate-target-actor` header) or
   by a `ResumeActor` RPC. C4 says "Runs push; the broker never dials into a sandbox", and a parked actor holds no SSE
   stream, so an approval cannot reach it without one of those paths.
3. **The Substrate API has no authorization.** `docs/authentication.md`: "Authorization and RBAC are not implemented
   yet, so only configure providers whose users should have full control of the entire control plane". The OpenFGA
   model is served, but "Checks are not enforced yet" (v0.2.0). Granting the broker (resume) or the factory (create)
   access means control over every actor. That exceeds SP2 T12's residual, and the C3 Kyverno one-creator rule cannot
   see Substrate API calls.
4. **One CPU model per `WorkerPool`**
   ([#1657](https://github.com/agent-substrate/substrate/issues/1657), open). A gVisor golden snapshot is pinned to the
   checkpointing host's CPU features, so a restore fails on a node missing one. Karpenter mixes families here.
5. **No spot workers** (#1528), plus a 30-minute eviction window (#1618). The repo is spot-first, and SP1 R7 already
   shows spot deletion ending runs; Substrate would not fix that on spot.
6. **Kueue gates pods; actors are not pods.** SP3's Kueue kill-switch layer and pod quota would not reach them.
7. **Cilium does not see individual actors.** Actors share worker pods (#1836) with a network namespace each (#1689).
   Egress goes atunnel → egress gateway, where "An actor without a policy has no egress". So constitution §3.1 holds
   only at the worker level. WebSocket is still blocked while HTTP/1.1 and HTTP/2 are allowed
   (`docs/egress-traffic.md`), so the r5 HTTPS bridge passes. Whether long-lived SSE survives the egress gateway is
   **UNVERIFIED**.
8. **Template env is literal-only.** "Kubernetes `envFrom`/`valueFrom` sources are not supported" (`docs/api-guide.md`
   L143). Secrets end up inline, against constitution §3.2, unless the egress credential injector is used. The
   Claude Code demo substitutes `ANTHROPIC_API_KEY` into its templates.
9. **Kubernetes API version skew.**
   - EKS's newest version is 1.36 ([EKS versions](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)).
     Whether EKS serves the beta `certificates.k8s.io/v1beta1` APIs is **UNVERIFIED**.
   - On 1.37 the APIs are v1-only, and Substrate's install "waits indefinitely" for a v1beta1 bundle (#1898, reproduced
     on AKS 1.37).
10. **ax suspend is not Substrate suspend.** Through ax, resume gives a new process tree (`docs/runner.md`). A harness
    conversation survives only if it is persisted under `/workspace`.
11. **Substrate needs its own PostgreSQL** (`manifests/ate-install/postgres`; Cloud SQL on GCP). Whether a `SQLInstance`
    claim can serve it is **UNVERIFIED**.

## Open questions surfaced

- [ ] Is parking a real cost at SP2's scale? At most 4 concurrent factory runs (SP3 §6.2) and a 4 h approval TTL. If
      not, Substrate's main SP2 advantage has no demand.
- [ ] Should harness memory on fork stay a non-goal? If it becomes a goal, pitfall 1 has to be designed around first.
- [ ] Do ADR-0044 and ADR-0048 list ax/Substrate among their rejected alternatives, or does ADR-0041 carry the whole
      evaluation, with the SP2 and SP3 findings added?
- [ ] Should the "EKS profile" trigger become concrete: EKS ships 1.37, #1898 closes, #1528 is lifted, #1657 is fixed?
- [ ] Does aws-0 (EKS 1.36) serve `certificates.k8s.io/v1beta1` ClusterTrustBundle and PodCertificateRequest? Settle
      with `kubectl api-resources --api-group=certificates.k8s.io`.
- [ ] If Substrate lands, would its opt-in agentgateway egress component, which sends the actor's SPIFFE identity to
      credential providers (`ed6d2a1`, agentgateway#3677), duplicate or displace Agent Router as the identity
      enforcement point (D11, OD-2)?
- [ ] Keep 2026-12-15 as the next re-check date?

## References

- Local:
  - `docs/superpowers/specs/2026-09-23-agent-runtime-identity-research.md`
  - `docs/superpowers/specs/2026-09-23-agent-factory-design.md`
  - `docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md`
  - `docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md`
  - `docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md`
  - `docs/platform-constitution.md` §3
  - `infrastructure/base/karpenter-nodepools/`
  - `opentofu/aws/eks/init/variables.tf`
- google/ax at `main`:
  - `README.md`, `DESIGN.md`, `docs/concepts.md`, `docs/runner.md`, `docs/roadmap.md`
  - [#376](https://github.com/google/ax/issues/376), [#363](https://github.com/google/ax/issues/363)
  - `gh api repos/google/ax/compare/d0bc38b...main` → identical
- Agent Substrate at `main`:
  - [v0.2.0 release](https://github.com/agent-substrate/substrate/releases/tag/v0.2.0)
  - `docs/architecture.md` ("Much of this architecture is aspirational"), `docs/roadmap.md`
  - `docs/api-guide.md` (L124, L143, L209, L316, L444), `docs/authentication.md`, `docs/egress-traffic.md`,
    `docs/request-parking.md`, `docs/threat-model.md`
  - `demos/claude-code-multiplex/README.md`, `cmd/atelet/main.go` L221–246, `manifests/ate-install/components/`
  - Issues: [#1898](https://github.com/agent-substrate/substrate/issues/1898), [#1657](https://github.com/agent-substrate/substrate/issues/1657),
    #432, #868, #1782, #1827
  - Commits `1d7ca8c`, `ed6d2a1`
- Kubernetes: [v1.37 Pod Certificates and Cluster Trust Bundles](https://kubernetes.io/blog/2026/08/28/kubernetes-v1-37-pod-certificates-and-cluster-trust-bundles/)
- EKS: [Kubernetes versions on standard support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions-standard.html)
- Context7: not used (no library docs needed; upstream source and issues read directly via `gh api`)
