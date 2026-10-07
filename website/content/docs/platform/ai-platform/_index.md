---
title: AI Platform
weight: 50
description: "Self-hosted model serving and the agent factory that puts models to work: vLLM behind Envoy AI Gateway, and sandboxed coding agents under their own identity."
lastVerified: 2026-10-01
---

Two halves, one platform. **Serving** runs open-weights models on the cluster's own GPUs behind an
OpenAI-compatible gateway. **Agents** put models to work: a labelled issue becomes a sandboxed agent
run that opens a pull request, under its own identity and in a room humans can watch and steer.

{{< callout type="warning" >}}
**Serving is off by default, and the agents are a work in progress.** What runs where, what is proven live and what
is planned lives on one page: [Status and roadmap]({{< relref "/docs/platform/ai-platform/status.md" >}}).
Every other page here describes the design.
{{< /callout >}}

## How the parts fit

![The AI Platform in one view. On the serving side, developers and coding clients send OpenAI-compatible requests over the tailnet to ai-gateway (Envoy AI Gateway with an API key and the Semantic Router), which routes them to vLLM models declared as InferenceService claims, on L4 GPUs and scaled by KEDA. On the agents side, a maintainer labels a GitHub issue; the Agent Factory turns it into a task, starts an agent run in a gVisor sandbox and opens a room the maintainer watches and steers. Every call the agent makes goes through the agent gateway with a per-run identity, to frontier models, MCP tools and octo-sts for a GitHub token; the agent pushes a branch and opens a PR. Both halves send traces, logs and metrics to the Victoria stack and Grafana](/images/diagrams/ai-platform-1.svg)

*Source: [`docs/architecture/ai-platform.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/ai-platform.drawio), page 1.*

| Part | What it does | Page |
|---|---|---|
| **Serving** | vLLM, one Crossplane `InferenceService` claim per model, on Karpenter L4 GPUs, scaled by KEDA | [Serving]({{< relref "/docs/platform/ai-platform/serving/_index.md" >}}) |
| **Gateways** | `ai-gateway` for humans and coding clients; the agent gateway for agent runs, with a per-run identity | [Gateways]({{< relref "/docs/platform/ai-platform/gateways.md" >}}) |
| **Coding clients** | OpenCode, Continue and OpenWebUI pointed at `ai-gateway` | [Coding clients]({{< relref "/docs/platform/ai-platform/coding-clients.md" >}}) |
| **Agents** | The factory, rooms and the sandboxed runtime | [Agents]({{< relref "/docs/platform/ai-platform/agents/_index.md" >}}) |
| **Observability** | vLLM, KEDA and gateway metrics; per-run traces, step logs and dashboards | [Observability]({{< relref "/docs/platform/ai-platform/observability.md" >}}) |

## Why self-host at all

A hosted API is cheaper, faster to adopt, and better at the frontier. This
platform exists for the things a hosted API cannot give you:

- **Prompts never leave the tailnet.** Every request path here is private —
  there is no public endpoint, and no third party sees the code being
  completed. That is the whole reason the coding fleet exists.
- **The model is pinned to a commit.** `model.revision` is a HuggingFace
  commit SHA, so the model behind an endpoint cannot change under you. A
  hosted endpoint's weights move when the provider decides.
- **Latency is a scheduling problem, not a queue you do not control.**
  Tab-completion needs sub-200 ms; that is achievable when the replica is
  yours and always warm, and not negotiable with a shared API.
- **It is a real workload for the platform to carry.** GPUs, spot reclaim,
  saturation-based autoscaling, a shared RWX filesystem and an
  ext_proc-filtered gateway exercise parts of this platform that a stateless
  web app never touches.

And the honest side of the ledger: there is **no scale-to-zero** — see
[Autoscaling & GPUs]({{< relref "/docs/platform/ai-platform/serving/autoscaling-and-gpu.md" >}})
for the four-GPU cost floor that implies, and why it is a deadlock rather
than a missing feature.

{{< cards >}}
  {{< card link="/docs/platform/ai-platform/serving/" title="Serving" icon="server" subtitle="Turning the opt-in serving platform on, what it deploys, and its security posture." >}}
  {{< card link="/docs/platform/ai-platform/serving/inference-service/" title="The InferenceService claim" icon="document-text" subtitle="One model, one YAML file — a complete claim with its reasoning intact, what it renders, and every field it accepts." >}}
  {{< card link="/docs/platform/ai-platform/serving/autoscaling-and-gpu/" title="Autoscaling & GPUs" icon="chip" subtitle="Three KEDA triggers on leading vLLM signals, the scale-to-zero deadlock, the gpu-l4 NodePool and S3 Files weights." >}}
  {{< card link="/docs/platform/ai-platform/gateways/" title="Gateways" icon="switch-horizontal" subtitle="ai-gateway for humans and coding clients, the agent gateway for agent runs: identity, routing and what they share." >}}
  {{< card link="/docs/platform/ai-platform/coding-clients/" title="Coding clients" icon="terminal" subtitle="Connecting OpenCode, Continue and OpenWebUI to the gateway — authentication, model IDs, and troubleshooting." >}}
  {{< card link="/docs/platform/ai-platform/agents/" title="Agents" icon="beaker" subtitle="Autonomous coding agents that run sandboxed under their own identity, collaborate with humans in rooms, and ship small changes." >}}
  {{< card link="/docs/platform/ai-platform/agents/runtime/" title="Agent runtime" icon="shield-check" subtitle="The gVisor sandbox, per-run identity, octo-sts and the rulesets that confine every run." >}}
  {{< card link="/docs/platform/ai-platform/agents/rooms/" title="Rooms" icon="chat-alt-2" subtitle="The append-only log of a task: live view, steering, room tools and approvals." >}}
  {{< card link="/docs/platform/ai-platform/agents/factory/" title="Factory" icon="cog" subtitle="From a labelled issue to a merged PR: intake, triage, teams, revise, the merge gate and the kill switch." >}}
  {{< card link="/docs/platform/ai-platform/agents/user-guide/" title="Agents user guide" icon="book-open" subtitle="How a developer gives work to agents, follows it, steers it and stops it." >}}
  {{< card link="/docs/platform/ai-platform/observability/" title="Observability" icon="chart-bar" subtitle="Serving metrics and alerts, and per-run traces, step logs, gen_ai metrics and dashboards." >}}
  {{< card link="/docs/platform/ai-platform/status/" title="Status and roadmap" icon="map" subtitle="The one place state lives: what serves, what is built, deployed and proven live, and the roadmap." >}}
{{< /cards >}}
