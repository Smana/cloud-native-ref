# Research: What should run an unattended agent factory on this platform, and what can let its low-risk PRs merge without a human?

**Topic**: agent-dark-factory · **Conducted**: 2026-09-23 · **Researcher**: Claude (subagent)

Companion to [the SP3 design](2026-09-23-agent-dark-factory-design.md). Options, not decisions.
Every version and repository state below was read on 2026-09-23 with `gh api repos/<r>` and
`gh api repos/<r>/releases/latest` unless another source is cited.

## TL;DR

- **Merge gate.** `palantir/policy-bot` is the only maintained OSS option found that evaluates
  path, size, author, branch and contributor predicates and reports **one commit status**, which a
  required check can pin to the bot's App ID. It reads `.policy.yml` from the **target** branch, so
  a PR cannot change the rules it is judged by. When no rule matches, it posts **`error`**, which
  blocks the merge.
- **This repo is owned by a user account.** For a user-owned repo, **merge queue is unavailable**
  and **push rulesets (file-path restrictions) are unavailable**. Repository rulesets *are*
  available, layer with classic branch protection, and accept a bypass list (admin role, GitHub
  Apps). So the gate has to act at **merge time**; blocking at push time is not possible here.
- **Orchestrator.** No OSS project combines GitHub-event-driven task lifecycles with per-task token
  budgets and a kill switch. Argo Workflows, Tekton and Temporal each supply part of it. Kueue
  provides admission, pod-count quotas and a `stopPolicy` hold/drain, and agent-sandbox documents
  a pod-level Kueue integration.
- **RunLore can already feed the factory.** Its `templated` notifier POSTs a Go-templated JSON body
  with an optional bearer token to any URL. No RunLore code change is needed.
- **GitHub does not redeliver failed webhooks**, so an intake built only on webhooks drops work
  without saying so. Polling, or webhooks plus a reconcile poll, closes that gap.

## Standard stack

| Component | Pick (candidate) | Version | Source |
|---|---|---|---|
| Merge policy engine | palantir/policy-bot (Apache-2.0, self-hosted, no DB) | v1.41.2 (2026-07-21); pushed 2026-09-20 | [repo](https://github.com/palantir/policy-bot), README §Configuration, §Security, §Deployment |
| Merge actor (optional) | GitHub native auto-merge via GraphQL `enablePullRequestAutoMerge` | — | GraphQL schema introspection (`gh api graphql … __type(name:"Mutation")`) |
| Revert primitive | GraphQL `revertPullRequest` (inputs: `pullRequestId`, `title`, `body`, `draft`, no branch name) | — | introspection of `RevertPullRequestInput` |
| Admission / quota | kubernetes-sigs/kueue (Apache-2.0) | v0.19.5 (2026-09-17) | [repo](https://github.com/kubernetes-sigs/kueue), [ClusterQueue docs](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/) |
| Sandbox | kubernetes-sigs/agent-sandbox | v1.0.3 (2026-09-17) | [repo](https://github.com/kubernetes-sigs/agent-sandbox), `examples/kueue-agent-sandbox/README.md` |
| Controller framework | kubernetes-sigs/controller-runtime | v0.25.1 (2026-09-14) | repo |
| GitHub App plumbing (Go) | palantir/go-githubapp (used by policy-bot) + google/go-github | v0.48.0 / v92.0.0 | repos |
| Agent GitHub credentials | octo-sts/app (programme C6, SP1) | v0.10.0 (2026-09-15) | [README](https://github.com/octo-sts/app) |
| Workflow engine (alt.) | argoproj/argo-workflows | v4.1.4 (2026-09-18) | repo |
| Pipeline engine (alt.) | tektoncd/pipeline | v1.16.0 (2026-08-31) | repo |
| Durable execution (alt.) | temporalio/temporal (MIT) | v1.32.0 (2026-09-11) | repo |
| External reference | github/gh-aw (MIT) | v0.89.21 (2026-09-23) | [overview](https://github.github.com/gh-aw/introduction/overview/) |
| External reference | OpenHands (MIT); standalone resolver repo **archived** | v1.23.0 | [All-Hands-AI/openhands-resolver](https://github.com/All-Hands-AI/openhands-resolver) (archived) |
| Merge bot (alt.) | palantir/bulldozer (Apache-2.0) | v1.19.3 (2025-06-26); pushed 2026-09-23 | repo |
| Merge bot (alt.) | chdsbd/kodiak (**AGPL-3.0**) | v0.59.1 (2026-03-13) | repo, `docs/docs/config-reference.md` |
| Merge bot (alt.) | Mergify: **engine source no longer public** | — | `Mergifyio/mergify-engine` resolves to `Mergifyio/mergify`, "Community Issue Tracker", last push 2023-09-07 |
| CI-native gate (alt.) | kubernetes-sigs/prow (tide) | no GitHub releases | repo |

## Facts that shape the design

### GitHub (verified against docs source `github/docs` and the live API)

| Fact | Consequence | Source |
|---|---|---|
| Merge queue: "available in any public repository owned by an **organization**" | Not available for `Smana/cloud-native-ref`. `strict: false` stays, and semantic conflicts are caught after merge | `data/reusables/gated-features/merge-queue.md` |
| Rulesets: "available in public repositories with GitHub Free" (users included) | A ruleset can carry the gate's required check | `data/reusables/gated-features/repo-rules.md` |
| Push rulesets (file paths): "Team plan in internal and private repositories" | An agent's push to `.policy.yml` or `.github/**` cannot be blocked at push time | same file; `push-rulesets-overview.md` |
| Rulesets "layer with protection rules … all rules apply", most restrictive wins | Adding a ruleset leaves the 8 classic checks and `enforce_admins` untouched | `about-rulesets.md` §About rule layering |
| Ruleset bypass: repo admins, maintain/write roles, teams, **GitHub Apps**, Dependabot; modes "Always" / "For pull requests only" | The gate can bind agents while the owner and Renovate keep a bypass | `rulesets-bypass-step.md` |
| Required status check rule: "select an app as the expected source" | policy-bot's status cannot be forged by anything holding `statuses: write` | `available-rules-for-rulesets` |
| App editing `.github/workflows/**` needs the **Workflows** permission | Leaving it out makes CI unmodifiable by agents, and GitHub enforces that | [choosing permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app) |
| "GitHub does not automatically redeliver failed deliveries" | Webhook-only intake silently loses work | [handling failed deliveries](https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries) |
| Apply/dismiss labels: **Triage** role minimum; Read ✗ | A label on a public-repo issue proves a collaborator acted | [repository roles](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization) |
| Live `main` protection: 8 contexts pinned to `app_id: 15368` (GitHub Actions), `strict: false`, 0 reviews, `enforce_admins`, conversation resolution required, **0 rulesets** | Review threads left by an agent block merge. Nothing binds rulesets yet | `gh api repos/Smana/cloud-native-ref/branches/main/protection`, `…/rulesets` → `[]` |
| Repo: owner type `User`, public, `allow_auto_merge: true`, squash-only | Auto-merge is already the Renovate path | `gh api repos/Smana/cloud-native-ref` |
| Renovate PRs are authored **and merged** by `app/renovate` with auto-merge (e.g. #2088, #2080, #2079) | Whoever enables auto-merge becomes the merge actor. Renovate must stay unaffected | `gh pr list --state merged --json author,mergedBy,autoMergeRequest` |

### policy-bot (README on `develop`, and source)

| Fact | Where |
|---|---|
| Policy read "from the most recent commit on the **target** branch" | README §Configuration |
| Missing policy → **no status posted**. Also falls back to a shared `.github` repo unless `options.shared_repository: ""` | README §Configuration, `config/policy-bot.example.yml` |
| Rule states: approved / pending / skipped / error. `skipped` "completely removes the rule" from `and`/`or` | README §Rules |
| All rules skipped → status **`error`**, "All rules were skipped. At least one rule must match." | `server/handler/eval_context.go` L153-155 |
| Status context is `"<status_check_context>: <base>"`, default `policy-bot: main` | `eval_context.go` L197; example config L123 |
| Predicates: `changed_files`, `no_changed_files`, `only_changed_files`, `file_added/not_added/deleted/not_deleted`, `has_author_in` (Apps as `name[bot]`), `has_contributor_in`, `only_has_contributors_in`, `author_is_only_contributor`, `targets_branch`, `from_branch`, `modified_lines` (additions/deletions/total, **OR** across conditions), `has_status`, `has_workflow_result`, `has_labels`, `title`, signatures, custom properties | README §Approval Rules |
| Options: `allow_author`, `allow_contributor`, `allow_non_author_contributor`, `invalidate_on_push`, `ignore_edited_comments`, `ignore_commits_by`, `request_review`, `methods` (comments / patterns / `github_review` / body patterns) | README §Approval Rules → options |
| Security caveats: statuses are forgeable **unless** an expected source is set. Comment edits by privileged users. Commit-email attribution can be spoofed. Push-time estimation for `invalidate_on_push` can lag | README §Security |
| Needs a public webhook (`/api/github/hook`, HMAC secret) and an OAuth callback for its UI. No database. Safe to run multiple replicas | README §Deployment |
| Repo permissions: statuses RW, pull requests RW, contents/checks/issues/actions/administration RO | README §GitHub App Configuration |
| `/api/validate` (syntax) and `/api/simulate/:org/:repo/:pr` (dry evaluation) endpoints | README §Testing and Debugging |

### Kueue and agent-sandbox

- agent-sandbox's Kueue example gates the **sandbox pod** through the label
  `kueue.x-k8s.io/queue-name` on `spec.podTemplate`. "Kueue controls when the sandbox starts, not
  how long it runs." (`examples/kueue-agent-sandbox/README.md`)
- ClusterQueue quotas accept the reserved resource `pods` to cap admitted pods. `stopPolicy: Hold`
  stops new admission. `HoldAndDrain` also evicts admitted workloads. Queueing is `StrictFIFO` or
  `BestEffortFIFO`. ([ClusterQueue](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/))
- Kueue knows nothing of tokens, tasks, or GitHub state. Budgets stay somewhere else.

### RunLore (local, `~/Sources/runlore` @ `c65a7ba7`)

| Fact | Where |
|---|---|
| `notify.templated`: named instances, Go-template body, optional `token_env` bearer, 256 KiB cap. A template that fails to parse refuses startup | `website/content/docs/integrations/notifications/templated.md` |
| `notify.webhook`: raw JSON POST, **no auth header** | `internal/notify/webhook/webhook.go` |
| Payload fields: `title, confidence, namespace, resource, resource_ref, curated_url, text, verdict, severity, cluster, environment, alert_name, started_at, occurrences, ruled_out, data_gaps, prior, matched_knowledge` | `internal/notify/payload.go` |
| Verdicts: `no_action`, `action_suggested`, `action_required`, `inconclusive` | `internal/providers/providers.go` L1986-1989 |
| KB curation quality bar `forge.min_confidence` defaults to **0.75** | `internal/config/load.go` L252 |
| Findings are secret-redacted before any notifier runs | templated.md §Notes |
| Deployed here: critical-only trigger, 30m dedup, coalescing on by default, GLM-5.2 via Z.ai | `observability/base/runlore/helmrelease.yaml` |

## Local patterns worth reusing

| Path | Why |
|---|---|
| `observability/base/runlore/httproute.yaml` + `infrastructure/aws-0/gapi/platform-public-gateway.yaml` | Precedent for exposing **one exact path, one method** on `platform-public`, with one listener per hostname and no wildcard. policy-bot's hook fits it |
| `observability/base/runlore/helmrelease.yaml` (`config` + strict `KnownFields` parse) | A config file that refuses to start on an unknown key. The factory's config should do the same |
| `observability/base/runlore/externalsecret-*.yaml` | Webhook bearer token and App key delivered by ESO |
| `clusters/aws-0/llm-platform.yaml` → `clusters/aws-0-llm-platform/` | The opt-in umbrella that C1 mirrors. Children are siblings so the recursive sync cannot bypass the suspend |
| `observability/base/grafana-operator/dashboards/*.yaml`, `observability/base/victoria-metrics-k8s-stack/vmrules/*.yaml` | Dashboard and VMRule conventions. `validate-vmrules.sh` gates `expr` |
| `.github/renovate.json` package rules | Existing automerge policy: patch/minor on green, never digests or Grafana plugins. The factory must neither redo nor contradict it |
| `.github/workflows/ci.yaml` `push: main` trigger | Post-merge validation of `main` already exists. It is the revert signal |
| Memory `required_check_cannot_be_path_filtered` | A new required check must always report. Read exact context strings from a live run |
| Memory `runlore_integration` (suspended `llm-platform` left a `VMServiceScrape` alerting on an absent workload) | Ship the factory's VMRules **inside** the umbrella so suspending it removes them |

## Don't hand-roll

| Problem | Use | Why |
|---|---|---|
| Approval-policy evaluation (review invalidation on push, edited comments, forged statuses) | policy-bot | Its README §Security lists the subtle failure modes it already handles |
| GitHub App auth, webhook HMAC, installation-token caching, rate-limit-aware client | go-githubapp + go-github | Shared with policy-bot and bulldozer |
| Controller reconcile loop, leader election, metrics endpoint | controller-runtime | Standard. The Task CR is its natural unit |
| Pod admission / global concurrency / drain | Kueue | Already integrates with agent-sandbox pods |
| Reverting a merged PR | GraphQL `revertPullRequest` | Produces the revert PR GitHub's own button would |
| Merging | GitHub native auto-merge | Waits for branch protection *and* rulesets. Renovate already relies on it |

## Common pitfalls

1. **A required check from an in-cluster service blocks every merge while that cluster is down.**
   Clusters here are torn down routinely. Put the check in a ruleset with a bypass list, or accept
   the outage.
2. **A PR that edits its own workflows changes the checks it is judged by** (`pull_request` runs
   the merge ref's workflow files). Only the absence of the App's `workflows` permission stops an
   agent doing this.
3. **Labels are not trust anchors**: any App with `issues`/`pull_requests` write can set them. Use
   labels to express intent and nothing else. Kodiak's `approve.auto_approve_labels` is this trap
   in product form.
4. **One bot login for agents and anything else** makes `has_author_in` meaningless. The agent
   App's login must be exclusive to agents.
5. **`modified_lines` is an OR across its conditions**, so "total < N **and** deletions < M" needs
   two rules.
6. **Review threads from an agent reviewer block merge** because `required_conversation_resolution`
   is on.
7. **Issue text can be edited after the trigger label is applied.** Snapshot the body and hash it
   at intake.
8. **`skipMissingSchemas: false`**: a new custom Kind committed to Git fails CI unless its schema
   is generated. Runtime-only kinds, such as Tasks created by the controller, are unaffected.
9. **Kueue gates pods, not intent.** A queued sandbox still holds its `AgentRun` and its
   ServiceAccount.
10. **`shared_repository` fallback**: without `options.shared_repository: ""`, a missing
    `.policy.yml` falls back to `Smana/.github`.

## Options surveyed (not decisions)

### Orchestrator

| Option | Strength | Weakness here |
|---|---|---|
| Custom controller + `Task` CRD | Matches the reconcile idiom; state lives in the CR; budgets and kill switch are first-class; no DB | We own the code |
| Crossplane `Task` XR (KCL) | Same idiom as `AgentRun` | Compositions are pure functions of observed state: no timers, no GitHub events. The release goes through `crossplane-configuration`. The KCL mutation trap applies |
| Argo Workflows | DAGs, retries, suspend/resume, semaphores, UI, archive | Long GitHub waits need suspend+resume or polling steps; one executor pod per resource step; a UI to secure; no budget concept |
| Tekton (+Triggers) | GitHub interceptors with HMAC | CI-shaped; no global queue; custom tasks needed to create `AgentRun`s |
| Temporal | Durable timers, signals, retries, best visibility | Server plus a persistence DB; code-first workflows; heavy for one small team |
| gh-aw | "Safe outputs": agent job read-only, separate jobs perform writes | Runs on GitHub Actions runners, outside D3/D9 |
| OpenHands resolver | `fix-me` label / `@openhands-agent` mention trigger | Uses a **PAT** and repo secrets (contradicts D3). Standalone repo archived |

Criteria matrix (✅ fits · ⚠️ with work · ❌ does not):

| Criterion | Custom controller | Argo Workflows | Tekton | Temporal | Crossplane XR | gh-aw |
|---|---|---|---|---|---|---|
| Config in Git, state at runtime | ✅ | ✅ | ✅ | ⚠️ workflows are code | ✅ | ❌ GitHub-side |
| Waiting hours on GitHub (CI, reviews, merge) | ✅ requeue | ⚠️ suspend/resume or poll pods | ⚠️ | ✅ timers, signals | ❌ no timers or events | ✅ on GitHub runners |
| Queueing and concurrency | ✅ caps + Kueue | ✅ semaphores | ❌ | ✅ | ❌ | ⚠️ |
| Per-task token budgets | ✅ written by us | ❌ | ❌ | ⚠️ in code | ❌ | ❌ |
| Footprint | 1 Deployment, no DB | controller + server + UI | controller + triggers | server + DB + workers | none | none in cluster |
| D3/D9 identity and sandbox | ✅ via `AgentRun` | ✅ | ✅ | ✅ | ✅ | ❌ |

### Merge gate

| Option | Predicates | Author-aware | Hosting | Licence | Gap here |
|---|---|---|---|---|---|
| policy-bot | paths, size, branch, contributors, labels, status | yes | self-hosted, public webhook | Apache-2.0 | Needs a public hook, and the check is down while the cluster is down |
| Required approving reviews | — | — | GitHub | — | A solo maintainer cannot approve their own PR. That is why the count is 0 |
| Rulesets + CODEOWNERS | paths only (via code-owner review) | no | GitHub | — | No size, author or contributor predicates, and no fail-closed "no rule matched" |
| Custom required check (Actions job) | anything we write | yes | GitHub | ours | Re-implements review invalidation, edited-comment and forgery handling; multiple check runs per event |
| Prow / tide | label-driven (`lgtm`, `approved`), OWNERS files | via OWNERS | a Prow deployment | Apache-2.0 | A whole Prow deployment for one repo |
| Mergify | rich | yes | SaaS | engine not public | SaaS-first (D2) |
| Kodiak | labels, title regex, usernames. **No path predicates** | usernames | self-host or SaaS | AGPL-3.0 | Its label-based auto-approve is pitfall 3 |
| bulldozer | a merge actor, not an approval engine | — | self-hosted | Apache-2.0 | GitHub native auto-merge already covers it |

## Open questions surfaced

1. Does GitHub auto-merge, enabled by an App that is on a ruleset's **bypass** list, still wait for
   that ruleset's required check, or merge as soon as the classic checks pass? UNVERIFIED. It
   decides whether Renovate can sit on the bypass list without behaviour changing.
2. Can a stock policy-bot container start and serve `/api/validate` without GitHub App credentials,
   so CI can syntax-check `.policy.yml`? UNVERIFIED.
3. Kueue pod integration inside a gVisor-only namespace: any interaction between scheduling gates
   and the RuntimeClass admission policy (C1 Kyverno)? UNVERIFIED.
4. Does the agent App's `pull_requests: write` let it submit an `APPROVE` review? Very likely yes.
   Irrelevant only if the policy counts named human users and never App reviews.
5. Cost per token for `tier-*` backends. SP4 owns the price table. Budget defaults here are
   in tokens and unpriced.

## References

- palantir/policy-bot README and `server/handler/eval_context.go`: https://github.com/palantir/policy-bot
- GitHub docs source (availability reusables): https://github.com/github/docs/tree/main/data/reusables
- About rulesets: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets
- Available rules for rulesets: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- Failed webhook deliveries: https://docs.github.com/en/webhooks/using-webhooks/handling-failed-webhook-deliveries
- GitHub App permissions: https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app
- Repository roles: https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization
- Kueue ClusterQueue: https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/
- agent-sandbox Kueue example: https://github.com/kubernetes-sigs/agent-sandbox/tree/main/examples/kueue-agent-sandbox
- octo-sts: https://github.com/octo-sts/app
- gh-aw overview: https://github.github.com/gh-aw/introduction/overview/
- OpenHands resolver (archived): https://github.com/All-Hands-AI/openhands-resolver
- Kodiak config reference: https://github.com/chdsbd/kodiak/blob/master/docs/docs/config-reference.md
- RunLore notifiers: `~/Sources/runlore/internal/notify/`, `website/content/docs/integrations/notifications/`
