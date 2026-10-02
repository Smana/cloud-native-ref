---
title: Rooms
weight: 20
description: "Work in progress. The shared, append-only log of a task: the broker, the bridge, the web view, steering, room tools, approvals, and roomctl."
lastVerified: 2026-10-01
---

A room is the shared, append-only log of a task: what each agent did, what humans said, the
handoffs between roles. Humans watch it live, post into it and steer the running agent; agents
collaborate through it, never by prompting each other. This page describes the design; what runs
today is on the [status page]({{< relref "/docs/platform/ai-platform/status.md#rooms" >}}).

![Rooms. A developer's browser reaches the web view through oauth2-proxy and ZITADEL single sign-on; roomctl offers the same room from a terminal. Both talk to the room-broker, which keeps each task's append-only log in PostgreSQL through CloudNativePG, with LISTEN/NOTIFY fanning new entries out to every broker replica. In each agent run, the room-bridge sidecar polls the harness and streams its events to the broker over TLS with a room token only it holds, and carries steering back. The agents' room tools reach the broker through the agent gateway. The broker posts a reviewer's verdict on the GitHub pull request](/images/diagrams/ai-platform-4.svg)

*Source: [`docs/architecture/ai-platform.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/ai-platform.drawio), page 4.*

## Components and software

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Room broker | A small Go service | Keeps each task's append-only log (agent steps, human messages, handoffs, approvals), serves it live, and posts a reviewer's verdict on the PR | A purpose-built log: the room is the audit trail, so it must be append-only and attributed |
| Log storage | PostgreSQL through [CloudNativePG](https://cloudnative-pg.io) | Durable, append-only storage; Postgres `LISTEN/NOTIFY` tells every broker replica that there is something new. Single instance; daily backup plus WAL archive; see the rooms design §4 for recovery objectives | The platform's standard database, and no second store for fan-out |
| Room bridge | A native sidecar in each run that joins a room | Polls the harness and streams its events to the broker over TLS, with a room token only it holds | The harness never talks to the broker, and never holds the room token |
| Web view | A small TypeScript UI behind oauth2-proxy and [ZITADEL](https://zitadel.com) SSO | Watch a room live, post or queue a message, steer or interrupt the run, hand to another role, approve an action | Single sign-on with the platform's identity provider; no framework, strict content security policy |
| Room tools | MCP tools served by the broker, through the agent router | Let agents read the room, post, hand over to another role, or record a verdict | Agents collaborate through the log, never by prompting each other |
| `roomctl` | A CLI | The same room from a terminal | For people who live in the shell |

## Steering, approvals and forks

From the [rooms design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-collaboration-rooms-design.md):

| Mechanism | How it works |
|---|---|
| **Messages** | A collaborator *queues* a message for the next run's brief. Only the driver *steers* the running run (injected at its next step) or *interrupts* it |
| **Driver token** | One per room. In a factory room the factory holds it and yields at once when a human requests it; driver-only actions carry an epoch that fences races across broker replicas |
| **Approvals** | Oversight, not a boundary: a run's capabilities are fixed at creation, and an agent run can never decide an approval |
| **Fork** | A new room from a prefix of the log, owned and driven by the person who forked it, on their budget. Widening a run's egress means forking; the fork's PR carries `Forked-from: <branch>@<sha>` |
| **Verdict** | A reviewer run records it with the room tools; the broker posts it on the PR as one comment. Advice only: it neither approves nor blocks |

Watching a room needs SSO membership in `agents-member`. The full transcript (prompts and outputs)
stays in the room; traces carry metadata only.

How a developer uses a room day to day is in the
[user guide]({{< relref "/docs/platform/ai-platform/agents/user-guide.md" >}}).
