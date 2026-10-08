---
title: Factory
weight: 30
description: "Work in progress. From a labelled issue to a merged PR: intake, triage, teams, revise, the merge gate and the kill switch."
lastVerified: 2026-10-01
---

The factory is the controller that turns a labelled issue into runs, narrates progress on the issue,
meters each run's tokens and owns the kill switch. It is the only component that creates runs, so
every run has a task and a budget. This page describes the design; what runs today is on the
[status page]({{< relref "/docs/platform/ai-platform/status.md#v1-what-shipped" >}}).

![The factory, from issue to merge. A maintainer labels a GitHub issue factory/ready; intake snapshots it, and triage picks the task's class, team and budget. The Task controller runs the team as sequential agent runs in one room: an implementer, then a reviewer, and a tester in the larger teams. Kueue admits each sandbox. The implementer opens a PR; a maintainer's "Request changes" review becomes a new run on the same branch. The merge gate, policy-bot and a separate merger App, merges only low-risk classes with green CI; every other PR waits for a human. The run meter revokes a run at its token cap, and the kill switch, a stop ConfigMap or a label on a pinned control issue, pauses intake and stops every task](/images/diagrams/ai-platform-5.svg)

*Source: [`docs/architecture/ai-platform.drawio`](https://github.com/Smana/cloud-native-ref/blob/main/docs/architecture/ai-platform.drawio), page 5.*

## From issue to merge

| Step | What happens |
|---|---|
| **Intake** | A maintainer adds `factory/ready` to an issue. The factory takes a snapshot of it, so a later edit does not change a task already under way, and comments with the run id, branch, budget and a *watch* link. A task already running refuses a second label |
| **Triage** | Once per task: which class it is (for example `docs-links`), which team of roles works it, and how big a budget it gets. A refusal is explained in a comment. What triage predicts only chooses the team and the budget; risk is enforced on the diff at merge time |
| **Teams** | Roles run as sequential `AgentRun`s in one room, on one `agent/<task>` branch: an implementer, then a reviewer, with a tester in larger teams. Only the implementer writes |
| **Revise** | A GitHub review with "Request changes" becomes the input of a new run on the same branch. `/factory retry` tries again after a failure |
| **Merge gate** | Only low-risk classes, and only with green CI and the policy agreeing: `docs-links` and `revert` (the factory's revert of an auto-merged `docs-links` change). Everything else waits for a human. In v1 the gate runs in shadow mode: it says what it *would* merge, and merges nothing |
| **Kill switch** | One task: the label `factory/stop`. Every task: the stop ConfigMap, or a label on a pinned control issue |

The developer's view of the same journey is in the
[user guide]({{< relref "/docs/platform/ai-platform/agents/user-guide.md" >}}).

## Components and software

| Component | Software | What it does | Why this software |
|---|---|---|---|
| Task controller | A Go controller (controller-runtime) | Turns a labelled issue into a task: snapshot, a room, the team's runs on its branch; narrates on the issue. Starts a reviewer after the implementer, and turns "Request changes" into a new run | The only component that creates runs, so every run has a task and a budget |
| Admission | [Kueue](https://kueue.sigs.k8s.io) | Queues sandboxes so a burst of tasks waits instead of overloading the node pool. Until it lands, the factory's own caps bound concurrency | The Kubernetes-native job queue, with quotas |
| Run meter and kill switch | Part of the controller | The run meter revokes any run, hand-launched ones included, at its token cap. The `agent-factory-stop` ConfigMap pauses intake and stops every task; so does a label on a pinned control issue | Controls that act from outside the sandbox |
| Merge gate | [policy-bot](https://github.com/palantir/policy-bot) and a merger GitHub App | Decides which agent PRs may merge themselves (only low-risk classes, green CI), then merges the PR at the head commit the checks ran on; only the factory's own revert PRs use GitHub's auto-merge. A separate App holds that right, and only it | The policy lives in the repository and is reviewable; the right to merge is isolated from everything else |
| Admission policy | [Kyverno](https://kyverno.io) | Denies `AgentRun` creation to anyone but the factory | One path in, so no run escapes its budget |

## Controls

| Boundary | Mechanism |
|---|---|
| Spend | Per-run deadline; the factory's run meter revokes a run at its token cap; token budgets at the gateway; at most 20 tasks a day |
| Merge | Only low-risk classes (`docs-links`, `revert`) merge themselves, through policy-bot and a separate merger App, and only once the gate leaves shadow mode (a v2 gate); everything else waits for a human |
| Stop | `kubectl -n agent-system create configmap agent-factory-stop` pauses intake and stops every task; one label on a pinned control issue also refuses new runs and revokes every running one |

The sandbox, identity and GitHub boundaries are on
[Runtime → Security boundaries]({{< relref "/docs/platform/ai-platform/agents/runtime.md#security-boundaries" >}}).
The [factory design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-dark-factory-design.md)
has the full merge policy, gate paths and the five-layer kill switch.
