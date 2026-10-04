# Agent factory: remaining work, in order

**As of 2026-10-04.** gcp-0 is torn down; the next session starts from here. Each step names the
plan that holds its tasks. The SDD ledgers (git-ignored, under
`.claude/worktrees/o1-agent-observability/.superpowers/sdd/<plan>/progress.md` on the owner's
machine) record what each plan has already done: read their tails before dispatching anything.

The order follows the dependencies: finish what is in review, put every fix that touches the
runtime into **one** re-pin and **one** rebuild, verify live, then change the gateway under it, then
build the rest.

| # | Step | Tasks in | Depends on | Owner action |
|---|---|---|---|---|
| 1 | Close the fixes in review: the scoped re-review of F15/F12 (round 1) and of SP2 Task 5.3 (round 1) | `2026-09-27-agent-collaboration-rooms-plan.md` | — | — |
| 2 | Merge `main` into every programme branch (the list is in the dark-factory ledger's `reports/docs-restructure-report.md`); the pre-push hook requires it | — | — | — |
| 3 | Disruption, runtime half: Tasks 1–7 (the bridge's final read, `agent-run`'s 15 s shutdown sequence, the composition's `Disrupted`/`PodLost`/`PodFailed`, no preStop, Crossplane's pod read, GKE Spot's 120 s window, docs) | [`2026-10-04-agent-run-disruption-plan.md`](2026-10-04-agent-run-disruption-plan.md) | 1: they stack on the F12/F15 branches | Push the harness pre-release image by hand (since #2179 CI pushes no PR images) |
| 4 | Disruption, factory half: Tasks 8–12 (automatic resume, reviewer rounds kept, dashboards, runbook 09) | same plan | 3 for the reasons it consumes. It merges `feat/factory-runlore`, so factory phases 2–9 reach gcp-0 (accepted) | — |
| 5 | One re-pin chain into `integration/agent-factory`: the crossplane-configuration pre-release (F12/F15 and the disruption composition), broker and bridge images (F10, F11, F12, F15, final read), the harness, the factory | the plans above | 1, 3, 4 | — |
| 6 | Rebuild gcp-0 from `integration/agent-factory`. Check GKE ≥ 1.35.0-gke.1171000 before applying the 120 s window | `opentofu/AGENTS.md` | 5 | Run the deploy |
| 7 | Live gates at that rebuild: re-verify F10, F11, F12, F15, F18; disruption Task 13 (acceptance 1–6); the pending SP2 and SP3 phase-1 gates. Then the two-day Substrate spike | the plans above; spike: `2026-10-04-kagent-evaluation-research.md` | 6 | Owner-only live steps |
| 8 | SP2 remaining: Task 5.4 (CC-S5/S5), 5.5 live, Task 0.5.15, Task 7.0, phase 6 (fork, `roomctl`), phase 7 (UX checkpoint) | `2026-09-27-agent-collaboration-rooms-plan.md` | 7 | — |
| 9 | The agentgateway migration, phases A–I, and phase J (provider-agnostic prompt caching, reference-token budgets). It replaces the gateway under every run, so it follows the live re-verification. SP4 PR 2's budgets move here | `2026-10-01-agent-router-agentgateway-plan.md` | 7 | Store the Anthropic API key in OpenBao (`bao kv put -mount=agents anthropic api_key=-`) |
| 10 | SP3 remaining: Task 3.4, 2.5 and 3.3 live, then phases 4–10 (triage, teams, Kueue, the merge gate in shadow, the merge wave) | `2026-09-27-agent-dark-factory-plan.md` | 9 for gateway budgets and tiers | — |
| 11 | aws-0, when rebuilt: the disruption FIS test, which decides the design's §5 early warning; the F7 PKI change | disruption plan Task 13 | — | Create the FIS IAM role |
| 12 | End-to-end UX walkthrough (label, room, request changes, approve, merge), then the merge wave to `main` | — | 1–10 | UX sign-off (P33) |

Re-check google/ax, Agent Substrate and kagent on **2026-12-15**, or earlier on any trigger listed
on the docs site's *Alternatives considered* page (`website/content/docs/platform/ai-platform/agents/alternatives.md`).
