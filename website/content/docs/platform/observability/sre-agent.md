---
title: SRE agent
weight: 50
description: RunLore — an LLM agent that receives Alertmanager webhooks, investigates them read-only against the live cluster, and writes what it learns back to a knowledge-base repository.
lastVerified: 2026-08-30
---

The rest of this section is about producing signals. This page is about the
thing that consumes them: an alert firing at 03:00 normally reaches a human
who then starts from nothing — reading the alert, opening dashboards,
correlating a deploy, remembering whether this happened before.

**RunLore** does that first pass. It receives the Alertmanager webhook,
investigates against the live cluster, posts a finding to Slack, and — when
the investigation taught it something — opens a pull request against a
knowledge-base repository so the next occurrence starts from the answer
rather than from nothing.

{{< callout type="warning" >}}
**It is read-only on the cluster.** `rbac.allowActions: false` and the
`actions` config block is omitted entirely, which means mode `off`. RunLore
has no patch rights on Flux resources and no ability to change cluster state.
Its only writes anywhere are pull requests and issues on its own knowledge-base
repository. It investigates and reports; a human still decides and acts.
{{< /callout >}}

## What happens to an alert

1. **A `VMRule` fires** and Alertmanager routes it to the `runlore` receiver.
   Only `severity: critical` is matched (`triggers.incidents.match`), with a
   30-minute dedup window on the alert fingerprint. Flux `Ready=False`
   conditions are a second, independent source.
2. **The webhook is authenticated.** RunLore fails closed: with a model
   configured, the alert webhook *must* carry a bearer token, because alert
   labels and annotations flow into the model prompt and therefore bill it.
   The token comes from an External Secret and Alertmanager posts it via
   `authorization.credentials_file`.
3. **Recall runs first.** The knowledge base is searched for a matching past
   investigation. On a high-confidence match the loop short-circuits — no
   full investigation, no model spend. This is the payoff of everything else
   on this page, and it is opt-in (`instant_recall.enabled: true`).
4. **Otherwise it investigates**, correlating Kubernetes object state, the
   GitOps change history, metrics from VictoriaMetrics and logs from
   VictoriaLogs — multi-source root cause, not just "what does `kubectl get`
   say".
5. **It posts the finding to Slack** in `#alerts`, with 👍/👎 feedback
   buttons.
6. **It drafts a knowledge-base PR**, unless the verdict was `no_action` —
   those are suppressed after pilot data showed 72% of drafted PRs over six
   days were closed as noise.

A trigger answered conclusively less than 30 minutes ago is not re-investigated
(`recurrence_cooldown`). That deliberately defers to humans: an inconclusive
verdict always retries, and a standing 👎 on the previous answer re-arms
investigation immediately.

## The knowledge base

The catalog is a separate repository, [`Smana/runlore-kb`](https://github.com/Smana/runlore-kb),
git-synced into the pod every 5 minutes at `/var/lib/runlore/catalog` — as a
**writable** mirror, so the loop is closed in both directions: recall reads
it, curation pushes pull requests to it through a GitHub App.

Alongside it sits an **outcome ledger** (`outcomes.jsonl`), which is what
turns accumulation into something closer to learning. A recall that never
resolves is rejected by the decay gate rather than being recommended forever,
and a 👎 in Slack feeds the same ledger.

Recall confidence is gated by an LLM reranker on a calibrated 0–1 match score
rather than a raw BM25 magnitude — which is what removed the need to hand-tune
scoring thresholds per corpus on this cluster.

## The model

GLM 5.2, reached over Z.ai's OpenAI-compatible API (`provider: openai` plus a
`base_url` — any provider name other than `anthropic` or `gemini` falls back
to the OpenAI wire protocol). The key arrives as `GLM_API_KEY` from an
External Secret; no credential is ever inlined.

## How it is deployed

| | |
|---|---|
| Chart | `deploy/helm/runlore` from the `runlore` `GitRepository` |
| Source | `flux/sources/gitrepo-runlore.yaml`, pinned to tag `v0.16.1` |
| Image | `0.16.1` — signed, multi-arch, SBOM-attested |
| Workload | `StatefulSet`, `replicaCount: 2`, leader election |
| Storage | one RWO 1Gi PVC per replica, via `volumeClaimTemplates` — platform default class (`gp3` on aws-0, `standard-rwo` on gcp-0) |
| Identity | `aws-0`: EKS Pod Identity `xplane-runlore` bound to the `runlore` ServiceAccount. `gcp-0`: a `GCPWorkloadIdentity` claim (`observability/gcp-0/runlore/workloadidentity.yaml`) — a direct principal binding carrying viewer roles only |
| Kustomization | `observability` |

{{< callout type="warning" >}}
**The chart tag and the image tag must move together.** The chart is rendered
from the `GitRepository` ref, and RunLore parses its config with
`KnownFields(true)` — so a chart newer than the binary emits config keys the
binary rejects and `serve` fails closed on startup. That is not a partial
upgrade, it is an outage: a v0.11.0 chart against a 0.9.2 binary crashlooped
both replicas on `field sweeps not found in type config.Curate` for as long as
the drift lasted. Note also that the image tag carries **no leading `v`**
(`0.13.0`, not `v0.13.0`) — GoReleaser publishes it that way, and a `v` prefix
lands the StatefulSet in `ImagePullBackOff`.
{{< /callout >}}

The `GitRepository` lives under `flux/sources/` rather than beside the
component under `observability/`, for the reason described in
[Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}}):
a source placed under an app-owned directory inherits that directory's
`sharding.fluxcd.io/key` label, and the default shard's controllers then
cannot see the `HelmChart` derived from it — surfacing as "source not found"
on some unrelated HelmRelease, far from the actual cause.

## Network posture

- **One public route, one path.** The `HTTPRoute` exposes **only**
  `POST /slack/interactions` on `runlore.<domain>`, so Slack can deliver
  button clicks; every request is HMAC-verified against the signing secret
  with a ±5 minute replay window. `/webhook/alertmanager`, `/metrics` and
  `/actions/*` deliberately have no route and the gateway answers 404.
- **Ingress is scoped to the `observability` namespace** — vmagent scrapes
  `/metrics`, Alertmanager and VMAlert post the incident webhook. Left empty,
  the chart emits no `from:` at all and every pod in the cluster could post to
  the webhook.
- **Two extra egress ports.** The chart's default egress opens only 443 and
  6443, but VictoriaMetrics listens on 8428 and VictoriaLogs on 9428 — without
  those, the agent's metrics and logs tool calls hang until they time out and
  every investigation runs half-blind against its own deadline.
- **The EKS Pod Identity endpoint** (`169.254.170.23:80`) is allowed as the
  `host` entity, which is required on Cilium — see
  [Policies]({{< relref "/docs/platform/security/policies.md" >}}).

## Its own observability

RunLore is scraped like anything else (`vmServiceScrape`, 30s, `/metrics`) and
carries a Grafana dashboard plus **12 `VMRule` alerts** on its own health:
`RunloreAgentDown`, `RunloreNoActiveLeader`, `RunloreMultipleLeaders`,
`RunloreInvestigationsDropped`, `RunloreInvestigationThrottlingSustained`,
`RunlorePipelineStalled`, `RunloreInvestigationErrors`,
`RunloreToolErrorRateHigh`, `RunloreModelErrorRateHigh`,
`RunloreModelLatencyHigh`, `RunloreSlowResolution` and
`RunloreInvestigationCostHigh` — the last of which is the one worth having:
an agent that investigates in a loop is a cost surface, not only a reliability
one. The 12 alerts ship from the base
(`observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml`) to
**both** clusters — they moved out of the `aws-0` overlay on 2026-08-30,
having stayed behind when the agent itself went multi-cloud. See
[Dashboards & Alerts]({{< relref "/docs/platform/observability/dashboards-and-alerts.md" >}}).

## Known gaps

- **Network signals are deferred.** The `network:` source needs a Hubble or
  flow-log provider choice, so investigations correlate Kubernetes state,
  GitOps history, metrics and logs — but not connectivity.
- **Recall thresholds are corpus-dependent.** The reranker removed the need to
  tune BM25 scores by hand, but `outcome_prior` and `outcome_floor` are still
  set from observed `recall_score` / `recall_rejections` behaviour rather than
  derived.
