---
title: Agent Factory
weight: 55
description: "Work in progress. Autonomous coding agents that run sandboxed under their own identity, collaborate with humans in rooms, and ship small changes end to end."
lastVerified: 2026-10-01
---

{{< callout type="warning" >}}
**Work in progress.** This section describes the target design. Running live on `gcp-0` from the
`integration/agent-factory` branch: the runtime and identity layer, the agent router's per-run
identity and model route, rooms (log, live view, room tools, steering), the factory's first phase
(intake, triage, one implementer per task, the run meter, the stop) and the per-run observability.
`aws-0` proved the runtime first; it is destroyed but still supported. Not live yet: the reviewer
pair and revise flow (built, not deployed), then approvals, `roomctl`, Kueue, the merge gate,
gateway budgets and the keyless Anthropic models (planned). Only these pages, the design documents
and the repository's trust policies are on `main`: the code merges once everything is built and its
user experience is signed off after a live walkthrough. The
[programme status]({{< relref "/docs/platform/agent-factory/status.md" >}}) has the detail.
{{< /callout >}}

## What it is

The LLM platform serves models; the agent factory puts them to work. A maintainer labels an issue,
and agents (an implementer, then a reviewer) work it on their own branch in a gVisor sandbox. They
open a pull request, and the factory narrates each step on the issue. Humans steer through GitHub reviews, or by
joining the agents' room. Only policy-defined low-risk changes merge themselves; everything else
waits for a human.

## New here? The ideas in two minutes

| Term | In plain words |
|---|---|
| **Agent** | A language model in a loop: it reads a task, runs tools (shell, git, file edits, queries), looks at the result and decides the next step, until the task is done or its budget runs out |
| **Harness** | The program that runs that loop inside the sandbox. Here it is [OpenHands](https://github.com/OpenHands/software-agent-sdk), wrapped by a small `agent-run` entrypoint that clones the repository, starts the conversation and prints a step log |
| **Run** | One agent, one role, one task, one branch, with a deadline. Declared as an `AgentRun` object in Kubernetes |
| **Role** | What a run is allowed to do. An *implementer* pushes to its own `agent/<id>` branch and opens a PR; a *reviewer*, *tester* or *triager* only reads and reports to the room, which posts a reviewer's verdict on the PR |
| **Sandbox** | The pod a run lives in, isolated by [gVisor](https://gvisor.dev) (a user-space kernel), with no long-lived credential and a network policy that denies everything not named |
| **Run identity** | A token issued for that run only. Every call to a model or a tool carries it, and the run exchanges it for a short-lived GitHub token, so every action is attributed to the run that made it |
| **agent-router** | The gateway every agent call goes through: it checks the run's token, meters its tokens and routes to the model. Budgets are planned |
| **Room** | A shared, append-only log of a task: what each agent did, what humans said, the handoffs between roles. Humans watch it live, post into it and steer the running agent. Approvals are planned |
| **Factory** | The controller that turns a labelled issue into runs, narrates progress on the issue, meters each run's tokens and owns the kill switch |
| **Merge gate** | *(planned)* The rule that decides which agent PRs may merge themselves: only low-risk classes, only with green CI |

The agent in the loop is not a trusted component. Every control sits **outside the sandbox**:
- network policy;
- per-run identity;
- scoped, short-lived GitHub tokens;
- branch and tag rulesets;
- token budgets;
- the merge gate.

## Architecture

The diagram shows the **target** architecture: the whole programme once built. Its legend marks
each box as live on `gcp-0`, built but not yet deployed, planned, or under evaluation.

![The Agent Factory's target architecture. Triggers: a GitHub repository (the factory/ready and factory/stop labels, a PR review asking for changes), RunLore findings (planned), the task agent:run CLI, a developer in a browser, and roomctl (planned). The factory turns a labelled issue into a task: intake, triage and narration, then the Task controller, which starts one implementer per task, opens a room and runs the run meter, with a kill switch beside it; all live. The reviewer pair and revise flow are built but not deployed; teams with a tester, Kueue admission and the merge gate (policy-bot and a merger App, auto-merge and rollback in shadow) are planned. Rooms: a web UI behind oauth2-proxy and ZITADEL SSO, the room-broker and its append-only CNPG log are live; approval cards and fork are planned. The runtime turns an AgentRun claim, through Crossplane, into a default-deny CiliumNetworkPolicy, projected tokens and a gVisor Sandbox pod holding the room-bridge sidecar, the OpenHands harness and an Envoy identity-proxy, on a GKE Sandbox pool on gcp-0 (live) or a Karpenter AL2023 pool on aws-0 (built). The proxy sends every call with a per-run JWT to Agent Router (Envoy AI Gateway 1.1.0), which routes to Z.ai GLM-5.3 (live), Claude on Bedrock for aws-0 and on Vertex AI for gcp-0 (planned), the MCP servers and octo-sts, which mints a token for the agents' GitHub App, confined by rulesets to agent/** branches and no tags. Agent Router also carries the agents' room_* tools to the broker; token budgets and tiers are planned, and an agentgateway PoC is under evaluation beside it. The room-bridge streams events to the broker over TLS with a room token, and the broker posts verdicts on the PR. Spans go through the agent-traces-collector to VictoriaTraces, step logs to VictoriaLogs, and access logs, gen_ai metrics and AgentRun state to VictoriaMetrics, all shown on the agent-run and agent-fleet Grafana dashboards. The same manifests deploy to gcp-0, the live cluster, and aws-0, destroyed and rebuilt on demand](/images/diagrams/agent-factory.svg)

*Source: [`docs/architecture/agent-factory.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/agent-factory.drawio).*

## Components and software

Everything that runs on the cluster is open source. The external services are GitHub and the model
providers. Each group is listed with its status.

### Runtime and identity: built, proven live

One `AgentRun` object becomes a fully isolated, fully attributed run. This part is proven end to
end on both clouds: an agent took issue #2112 to PR #2114 on `aws-0`, which was merged, and issue
#2140 to PR #2141 on `gcp-0`.

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Run API | [Crossplane](https://www.crossplane.io) v2 composition, written in KCL | Turns one `AgentRun` claim into everything a run needs: ServiceAccount, task ConfigMap, network policy, Sandbox. Projects the run's phase, PR and token usage back into its status | The platform's standard for self-service APIs; one claim, one lifecycle, deleted as a whole |
| Sandbox lifecycle | [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | A `Sandbox` resource: one pod with a stable identity and a clean start, and no restarts that hide failures | Kubernetes-native and built for agent workloads; the same building block as AWS's agents-on-EKS blueprint |
| Isolation | [gVisor](https://gvisor.dev) (`runsc`) on a dedicated pool: GKE Sandbox `agents-gvisor` on `gcp-0`, [Karpenter](https://karpenter.sh) `agents-gvisor` on `aws-0` | Runs the agent's commands against gVisor's user-space kernel, so an exploit has to break gVisor before it reaches the node's kernel | Strong isolation without VMs, and it runs on ordinary nodes (Kata would need bare metal or nested virtualisation) |
| Harness | [OpenHands](https://github.com/OpenHands/software-agent-sdk) agent-server and SDK, wrapped by a small `agent-run` entrypoint | The agent loop: shell, editor, git, MCP tools. `agent-run` clones the repository, starts the conversation, prints the step log and revokes the GitHub token at the end | Open source, headless (an HTTP API rather than an IDE), model-agnostic, with MCP support |
| Identity proxy | [Envoy](https://www.envoyproxy.io) sidecar | Attaches the run's own short-lived token to every model, tool and token-exchange call. The harness never sees that token | The agent cannot leak a gateway token it never sees. The one credential it holds is its GitHub token: in memory, one repository, one role, ≤ 1 h, revoked when the run ends |
| Network policy | [Cilium](https://cilium.io) `CiliumNetworkPolicy` | Default deny, per run: egress only to named hosts (GitHub, the router, optional package registries) | FQDN-aware policy, plus Hubble to see every dropped flow |
| GitHub access | [octo-sts](https://github.com/octo-sts/app) and a GitHub App, plus a repository ruleset | Exchanges the run's identity for a GitHub token scoped to one repository and its role's permissions, valid ≤ 1 h and revoked when the run ends. The rulesets let the App push only `agent/**` branches, and no tags | No long-lived GitHub token anywhere; the rules live in each repository's trust policies |
| Secrets | [OpenBao](https://openbao.org) and [External Secrets](https://external-secrets.io) | Holds the few platform secrets (App keys, provider keys); none reaches a sandbox | The platform's secret store, nothing agent-specific |

### Agent router: identity and routing built; budgets and tiers planned

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Gateway | [Agent Router](https://theagentrouter.ai) 1.1.0 (Envoy AI Gateway) on [Envoy Gateway](https://gateway.envoyproxy.io) | Verifies each run's token (JWT), attributes and meters every request to its run, routes the model alias to a provider. *(Planned)* per-run and fleet token budgets, and routing by tier | One gateway for models, tools and token exchange, with per-run identity in every access-log line |
| Models | Z.ai GLM-5.3 for `public` runs today; *(planned)* Anthropic Claude for `internal` runs, through Amazon Bedrock on `aws-0` and Vertex AI on `gcp-0` | The providers the router sends model calls to. Agents ask for an alias, never for a provider | Swapping or adding a provider changes the router, not the agents |
| Tool servers | [MCP](https://modelcontextprotocol.io) servers for Flux Operator, VictoriaMetrics and VictoriaLogs, read-only, and the room-broker's `room_*` tools | `public` runs get documentation tools only; cluster, metric and log reads are for `internal` runs (planned: they await a model route). The room tools are routed per role | Agents investigate with the data humans use, under the same identity checks |

*Under evaluation:* an [agentgateway](https://agentgateway.dev) proof of concept runs beside Agent
Router on `gcp-0`; its result decides whether it replaces Agent Router.

### Rooms: built (log, live view, room tools, steering); approvals and `roomctl` planned

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Room broker | A small Go service | Keeps each task's append-only log (agent steps, human messages, handoffs; approvals planned), serves it live, and posts a reviewer's verdict on the PR | A purpose-built log: the room is the audit trail, so it must be append-only and attributed |
| Log storage | PostgreSQL through [CloudNativePG](https://cloudnative-pg.io) | Durable, append-only storage; Postgres `LISTEN/NOTIFY` tells every broker replica that there is something new | The platform's standard database, and no second store for fan-out |
| Room bridge | A native sidecar in each run that joins a room | Polls the harness and streams its events to the broker over TLS, with a room token only it holds | The harness never talks to the broker, and never holds the room token |
| Web view | A small TypeScript UI behind oauth2-proxy and [ZITADEL](https://zitadel.com) SSO | Watch a room live, post or queue a message, steer or interrupt the run, hand to another role; *(planned)* approve an action | Single sign-on with the platform's identity provider; no framework, strict content security policy |
| Room tools | MCP tools served by the broker, through the agent router | Let agents read the room, post, hand over to another role, or record a verdict | Agents collaborate through the log, never by prompting each other |
| `roomctl` | *(planned)* A CLI | The same room from a terminal | For people who live in the shell |

### Agent factory: intake, triage, run meter and stop built; teams and the merge gate to come

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Task controller | A Go controller (controller-runtime) | Turns a labelled issue into a task: snapshot, triage, a room, an implementer run on its branch; narrates on the issue. *(Built, not deployed)* a reviewer after the implementer, and "Request changes" turned into a new run | The only component that creates runs, so every run has a task and a budget |
| Admission | *(planned)* [Kueue](https://kueue.sigs.k8s.io) | Queues sandboxes so a burst of tasks waits instead of overloading the node pool. Until it lands, the factory's own caps bound concurrency | The Kubernetes-native job queue, with quotas |
| Run meter and kill switch | Part of the controller | The run meter revokes any run, hand-launched ones included, at its token cap. The `agent-factory-stop` ConfigMap pauses intake and stops every task; *(planned)* a label on a pinned control issue | Controls that act from outside the sandbox |
| Merge gate | *(planned)* [policy-bot](https://github.com/palantir/policy-bot) and a merger GitHub App | Decides which agent PRs may merge themselves (only low-risk classes, green CI), then arms GitHub's auto-merge. A separate App holds that right, and only it | The policy lives in the repository and is reviewable; the right to merge is isolated from everything else |
| Admission policy | *(planned)* [Kyverno](https://kyverno.io) | Denies `AgentRun` creation to anyone but the factory | One path in, so no run escapes its budget |

### Observability: built

| Component | Software | What it does |
|---|---|---|
| Logs | [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) | Every run's step log and every gateway call, attributed to the run |
| Metrics | [VictoriaMetrics](https://victoriametrics.com) | Tokens, cost, latency and errors per run, and each `AgentRun`'s state through kube-state-metrics |
| Traces | [VictoriaTraces](https://docs.victoriametrics.com/victoriatraces/), behind an OpenTelemetry Collector that keeps only allowlisted metadata | One trace per run: steps, model calls and tool calls. Metadata only: no prompts or outputs. Known issue (round 9, F16): MCP tool calls are not yet joined to the run's trace |
| Dashboards | [Grafana](https://grafana.com) | `agent-run`, one page per run, and `agent-fleet`, the overview. Known issue (round 9, F18): a successful run's page lacks its outcome and PR |

## One repository at first

The design targets one repository at first. Nothing in it is tied to that repository: the agents'
App, the trust policies and the rulesets live in the repository they protect, and every
token audience names its repository. A second repository is a planned extension, not a step you
can take today. It would need:

1. The agents' GitHub App installed on it, and the factory's App for narration.
2. The octo-sts trust policies for the roles it allows, in that repository.
3. The `agent/**` branch ruleset and the tag ruleset applied to it.
4. Two platform changes: its four audiences added to the gateway's token-exchange listener (at
   most eight per listener), and a factory intake that polls more than one repository.

Runs are per repository: a task never spans two.

## Security boundaries

| Boundary | Mechanism |
|---|---|
| Code execution | gVisor sandbox, restricted pod security, no service-account token in the harness |
| Network | Default-deny CNP per run; egress only to named FQDNs and the gateway |
| Identity | Two projected tokens per run, for the gateway and for token exchange, valid until the deadline; each audience names the run's role and its data class or repository. A room run adds a third, audience `room-broker`, refreshed every 600 s and held only by the room-bridge sidecar |
| GitHub | Short-lived installation tokens from octo-sts, scoped to one repository and the role's permissions; rulesets let the agents' App push only `agent/**` branches, and no tags |
| Spend | Per-run deadline; the factory's run meter revokes a run at its token cap; *(planned)* token budgets at the gateway |
| Merge | *(planned)* Only low-risk classes (`docs-links`, `revert`) auto-merge, through policy-bot and a separate merger App; everything else waits for a human |
| Stop | `kubectl -n agent-system create configmap agent-factory-stop` pauses intake and stops every task; *(planned)* one label on a pinned control issue that also refuses new runs and revokes every running one |

## Design documents

- [Programme design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-factory-design.md): the contracts between the sub-projects, and the owner decisions.
- [Runtime and identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md) · [Rooms](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md) · [Factory](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md) · [Model routing and budgets](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-llm-complexity-routing-design.md) · [Observability](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-27-agent-observability-design.md)
- [User guide]({{< relref "/docs/platform/agent-factory/user-guide.md" >}}): what a developer does with it.
- [Programme status]({{< relref "/docs/platform/agent-factory/status.md" >}}): what is built, reviewed and proven live, and what waits on the owner.
