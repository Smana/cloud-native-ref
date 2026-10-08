---
title: Runtime
weight: 10
description: "Work in progress. How one AgentRun becomes an isolated, attributed run: a gVisor sandbox on each cloud, per-run identity, octo-sts, branch and tag rulesets, and default-deny network policy."
lastVerified: 2026-10-01
---

One `AgentRun` object becomes a fully isolated, fully attributed run. The agent in the loop is not
trusted, so every control on this page sits outside the sandbox. This page describes the design;
what runs today is on the [status page]({{< relref "/docs/platform/ai-platform/status.md#v1-what-shipped" >}}).

![The agent runtime. An AgentRun claim goes through a Crossplane composition, which renders a ServiceAccount with projected tokens, a default-deny CiliumNetworkPolicy and a Sandbox. The Sandbox pod runs under gVisor on a dedicated pool, GKE Sandbox on gcp-0 or Karpenter on aws-0. Inside it, the OpenHands harness never holds the run token: the Envoy identity-proxy sidecar attaches it to every call to the agent gateway, and the room-bridge sidecar holds the room token. The gateway's token exchange reaches octo-sts, which mints a short-lived GitHub token for the agents' App, confined by rulesets to agent/** branches and no tags. OpenBao and External Secrets hold the platform's secrets, none of which reach the sandbox](/images/diagrams/ai-platform-3.svg)

*Source: [`docs/architecture/ai-platform.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/ai-platform.drawio), page 3.*

## Components and software

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

## Security boundaries

| Boundary | Mechanism |
|---|---|
| Code execution | gVisor sandbox, restricted pod security, no service-account token in the harness |
| Network | Default-deny CNP per run; egress only to named FQDNs and the gateway |
| Identity | Two projected tokens per run, for the gateway and for token exchange, valid until the deadline; each audience names the run's role and its data class or repository. A room run adds a third, audience `room-broker`, refreshed every 600 s and held only by the room-bridge sidecar |
| GitHub | Short-lived installation tokens from octo-sts, scoped to one repository and the role's permissions; rulesets let the agents' App push only `agent/**` branches, and no tags. Confinement is per repository: any run may push any `agent/**` branch, with no per-run branch isolation |

Spend, merge and stop are the factory's controls: see
[Factory → Controls]({{< relref "/docs/platform/ai-platform/agents/factory.md#controls" >}}).
