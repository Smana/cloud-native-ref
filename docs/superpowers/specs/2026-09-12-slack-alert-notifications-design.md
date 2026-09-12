# Slack alert notifications

**Date**: 2026-09-12
**Status**: Design — approved, not implemented
**Touches**: `observability/base/victoria-metrics-k8s-stack/`, both `configure` stacks, `scripts/`
**Requires before merge**: `website/content/docs/decisions/0037-alertmanager-native-slack-templates.md` (not yet written)

## The problem

Every alert on both clusters lands in one Slack channel rendered by the
**Monzo templates**, which the `victoria-metrics-k8s-stack` chart vendors
read-only at
`templates/victoria-metrics-operator/vmalertmanager/monzo-template.yaml` and
enables by default. They were written in 2018 for a single cluster, and the
platform now runs two, on two clouds.

Three consecutive messages observed on 2026-09-12, verbatim:

```
[FIRING:1] :warning: TargetDown
 • 100% of the core-dns/victoria-metrics-k8s-stack-core-dns targets in
   kube-system namespace are down.
Runbook :green_book:  Dashboard :grafana:  Silence :no_bell:

[FIRING:1] :fire: OpenBaoRaftQuorumAtRisk
 • OpenBao raft cluster cannot tolerate a node failure.
 • Failure tolerance has been below 1 for 15 minutes: losing one more
   node loses quorum, and a cluster without quorum cannot issue a
   certificate or read a secret. [...]

[FIRING:1] :warning: OpenBaoRaftNodeLost
 • OpenBao raft cluster has lost redundancy.
 • Failure tolerance has been below 2 for 15 minutes [...]
   Compare the voter list against the running instances:
     bao operator raft list-peers
     aws autoscaling describe-auto-scaling-groups --region <region> [...]
```

What that costs, item by item:

1. **No cluster, environment, cloud or region anywhere in the message.**
   `TargetDown` on `aws-0` and `TargetDown` on `gcp-0` are indistinguishable.
   The route already groups on `cluster` — the template simply never prints it.
2. **A runbook is pasted into the channel.** `OpenBaoRaftNodeLost` ships twelve
   lines of shell in its `description`, and the template prints annotations in
   full.
3. **Two alerts for one fault.** Quorum-at-risk strictly implies a lost peer,
   and both posted within the same minute. There are **no `inhibit_rules`** —
   the chart's defaults are replaced wholesale by
   `alertmanager.config` in `vm-common-helm-values-configmap.yaml`.
4. **`summary` is never rendered.** The template prints `message` and
   `description` only, so the 26 repo alerts that follow the upstream
   `summary` + `description` convention show their long half and not their
   short one.
5. **Labels are dropped.** namespace, pod, instance, job, region — all present
   on the alert, none displayed.
6. **No duration.** Nothing says whether this started 30 seconds or 6 hours ago.
7. **Dead buttons.** The fifth action's URL is `.CommonAnnotations.link_url`,
   an annotation no rule in this repo sets.
8. **One repeat cadence for every severity** (`repeat_interval: 3h`), so a
   warning nags as often as a page.
9. **`fallback` is unset**, which is the string Slack shows in push
   notifications and channel previews.

## Decisions taken

| Question | Decision |
|---|---|
| Channel layout | **One channel.** Everything goes into the message, no per-severity or per-cluster channels |
| Message density | **Rich and uniform** — identity, summary, per-instance detail, label grid, duration, on every severity including resolved |
| Identity labels | **cluster + env + cloud + region**, accepting a new `cloud` ConfigMap key on both clouds |
| VMRule annotations | **Tolerant template + normalize repo rules + a gate** |
| Noise | **Inhibition + per-severity `repeat_interval`** |
| Delivery mechanism | **`alertmanager.templateFiles`** in the existing values ConfigMap |

## Mechanics verified before designing

- **`alertmanager.templateFiles`** is a first-class chart key. It renders a
  `<fullname>-extra-tpl` ConfigMap, and `_helpers.tpl:308-311` appends it to
  `VMAlertmanager.spec.templates`. Values are inserted raw
  (`{{ $template | nindent 4 }}`, no `tpl`), so Go template syntax survives
  Helm. `monzoTemplate.enabled: false` drops the vendored template.
- **Flux post-build substitution only expands `${var}`**; a bare `$var` passes
  through untouched. Go template variables are therefore safe, and a literal
  `${` is the single forbidden sequence in the template body. (This is also why
  `{{ $labels.name }}` in `vmrules/cert-manager.yaml` has always been correct.)
- **`since` and `humanizeDuration` exist** in Alertmanager's function set, and
  the chart pins `alertmanager v0.32.1` (`values.yaml:1586-1587`), far past the
  release that added them.
- **There is no `default` function.** Alertmanager ships no sprig: the set is
  `append base64decode base64encode date dict humanizeDuration join list match
  now reReplaceAll routeLabels safeHtml safeUrl since stringSlice title toJson
  toLower toUpper trimSpace tz urlUnescape`. Every optional value is guarded
  with `{{ with }}…{{ else }}`.
- **`amtool template render`** renders a named template against a JSON fixture
  with no cluster and no running Alertmanager.

## Design

### 1. Identity labels

`vmalert.spec.externalLabels` gains three labels beside the existing `cluster`:

```yaml
vmalert:
  spec:
    externalLabels:
      cluster: "${cluster_name}"
      env:     "${environment}"
      cloud:   "${cloud}"
      region:  "${region}"
```

On **vmalert only**, not vmagent. vmalert's external labels are attached after
rule evaluation, so no aggregation can drop them, and they land on alerts plus
recording-rule output — a few hundred series. The same labels on vmagent would
attach to every scraped series in the TSDB, which is a real cardinality cost for
a presentation feature.

`group_by` is unchanged. `env`, `cloud` and `region` are functionally dependent
on `cluster`; adding them would only lengthen silence URLs.

### 2. The `cloud` ConfigMap key

`environment` and `region` already exist in both clusters' `flux_cluster_vars`.
`cloud` does not, and needs three edits:

| File | Change |
|---|---|
| `opentofu/aws/eks/configure/kubernetes.tf` | `cloud = "aws"` |
| `opentofu/gcp/gke/configure/kubernetes.tf` | `cloud = "gcp"` |
| `scripts/flux-schema/render-bundle.py` (`FIXTURES`) | `"cloud": "aws"` |

`check-substitution.py` needs no edit — it reads both `.tf` files directly and
picks the key up on its own.

**Ordering.** The key exists only after `terramate script run deploy` on each
`configure` stack. A manifest that merges first renders `cloud: ""` — schema
valid, silently wrong, exactly the failure that check exists to catch. Two
consequences are designed in: the template renders correctly with an empty or
absent `cloud`, and the PR body carries the apply-first instruction for both
clusters.

### 3. Message anatomy

```
┃ 🔥 FIRING — OpenBaoRaftQuorumAtRisk
┃ `aws-0 · dev`
┃
┃ OpenBao raft cluster cannot tolerate a node failure.
┃ Failure tolerance has been below 1 for 15 minutes: losing one more node
┃ loses quorum, and a cluster without quorum cannot issue a certificate or
┃ read a secret. If OpenBaoRaftNodeLost fired first and was not…
┃
┃ Namespace        Severity
┃ security         critical
┃ Firing since     Location
┃ 09:06 (14m)      aws / eu-west-3
┃
┃ [ Runbook 📗 ] [ Dashboard 📊 ] [ Query 🔍 ] [ Silence 🔕 ]
```

```
┃ ⚠️ FIRING · 3 — KubePodCrashLooping
┃ `gcp-0 · dev`
┃
┃ Pod is restarting repeatedly.
┃  • apps/podinfo-7d8f — 12 restarts in 10m
┃  • apps/podinfo-9f2c — 8 restarts in 10m
┃  • apps/podinfo-b1a4 — 5 restarts in 10m
┃
┃ Namespace  apps          Severity   warning
┃ Firing since 09:12 (4m)  Location   gcp / europe-west1
```

`fields` is a static list in the receiver and only its *values* are templated,
so the split between config and template is not cosmetic:

| Slack field | Owner | Content |
|---|---|---|
| `fallback` | receiver | `[FIRING:3] KubePodCrashLooping · gcp-0/dev · warning` — what push notifications and previews show; unset today |
| `color` | template | `danger` / `warning` / `#439FE0` / `good` |
| `title` + `title_link` | template | status · count · alertname, linked to the dashboard else `GeneratorURL` |
| `text` | template | identity line, summary once, then ≤5 per-alert bullets, then `…and N more` |
| `fields` (4, `short: true`) | receiver | Namespace · Severity · Firing since · Location |
| `actions` | receiver | four buttons; the always-empty `link_url` one is deleted |

Rules the template follows:

- **Headline resolution order `summary` → `message` → `description`.** Required
  regardless of what happens to this repo's rules, because chart-shipped rules
  are not ours to change.
- **Per-alert detail truncated at 180 bytes** with the `slice` builtin plus an
  ellipsis. **The VMRules keep their full descriptions**: RunLore receives the
  same annotations over its webhook, and trimming the OpenBao raft prose out of
  the rule would blind the agent to the one thing that explains the alert.
  Slack gets the short form; the agent gets everything.
- **Missing labels render `—`**, never a blank field box. A node-level alert has
  no namespace and must still look deliberate.
- **Resolved is uniform** — same anatomy, `good` colour, `:lgtm:`, with *Firing
  since* replaced by *Resolved after 14m*.
- **No button is ever dead.** runbook → `runbook_url` else the alerting docs
  page; dashboard → `dashboard` else `https://grafana.${private_domain_name}/dashboards`;
  query → `GeneratorURL`, which vmalert always sets.
- **`__alert_silence_link` is redefined by us.** It is defined in the Monzo
  template we are disabling, and losing the Silence button silently would be
  the obvious regression.

### 4. Noise policy

```yaml
route:
  repeat_interval: 12h
  routes:
    - matchers: [alertname=~"InfoInhibitor|Watchdog|KubeCPUOvercommit"]
      receiver: blackhole
    - receiver: runlore
      continue: true
    - matchers: [severity="critical"]
      receiver: slack-monitoring
      group_wait: 10s
      repeat_interval: 1h
    - matchers: [severity="warning"]
      receiver: slack-monitoring
      repeat_interval: 12h
    - receiver: slack-monitoring
      repeat_interval: 24h

inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [cluster, alertname, namespace]
  - source_matchers: [alertname="OpenBaoRaftQuorumAtRisk"]
    target_matchers: [alertname="OpenBaoRaftNodeLost"]
    equal: [cluster]
```

The generic rule catches one alertname firing at two severities. The pair
observed on 2026-09-12 is **two different alertnames** where one implies the
other, so it needs the explicit second rule. Named pairs get added as they are
observed; a clever generic rule would mute things nobody intended.

An inhibited warning never reaches Slack at all. That is the accepted trade.

### 5. Annotation contract

Ground truth, 45 alerts across 10 repo-authored VMRule files:

| File | alerts | `summary` | `message` | `runbook_url` |
|---|--:|--:|--:|--:|
| `observability/base/victoria-metrics-k8s-stack/vmrules/runlore.yaml` | 12 | 12 | 0 | 12 |
| `observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml` | 7 | 0 | 7 | 7 |
| `apps/base/ai/llm/vmrule-llm-slo.yaml` | 8 | 8 | 0 | 1 |
| `infrastructure/base/cilium/vmrules.yaml` | 4 | 2 | 2 | 4 |
| `apps/base/ai/llm/vmrule-ai-fleet.yaml` | 4 | 4 | 0 | 0 |
| `flux/observability/vmrule.yaml` | 3 | 0 | 3 | 3 |
| `observability/aws-0/victoria-metrics-k8s-stack/vmrules/karpenter.yaml` | 3 | 0 | 3 | 3 |
| `observability/base/victoria-metrics-k8s-stack/vmrules/cert-manager.yaml` | 2 | 0 | 2 | 2 |
| `observability/base/kubernetes-event-exporter/vmrule.yaml` | 1 | 0 | 1 | 0 |
| `observability/base/loggen/demo-vmrule.yaml` | 1 | 0 | 1 | 0 |

The contract:

- **`summary` — required.** One line, ≤140 characters, the sentence a human
  reads first.
- **`description` — optional**, any length. Detail and procedure. Slack
  truncates it; RunLore does not.
- **`runbook_url` — optional.** 13 alerts lack one and this change does not
  write runbook pages; the template's fallback covers them rather than the gate
  demanding URLs that do not exist.
- **`dashboard` — optional.** The chart already injects a default for its own
  rules via `defaultRules.rule.spec.annotations`.

Normalizing is a **`message:` → `summary:` rename in 7 files, 19 occurrences**.
After it all 45 alerts carry a summary, so the gate ships with **no
exemption list** — which matters, because a gate that ships with a skip-list is
a gate people learn to add to.

### 6. Gates

**`scripts/validate-vmrules.sh`** gains a second pass after promtool: every
repo-authored `alert:` must carry a non-empty, single-line `annotations.summary`
of ≤140 characters. Recording rules are skipped. It goes in this script because
it already walks exactly the right file set — repo-authored VMRules, not
chart-shipped ones — and already knows to skip `type: vlogs` groups.

**`scripts/validate-alertmanager-templates.sh`** is new. `mise.toml` gains
`alertmanager = "0.32.1"`, matching the chart's pin, for the same reason the
`promtool` pin exists: the renderer *is* the gate.

It tests the **rendered** artifacts, not the sources. From `.bundle/` it
extracts both the `…-extra-tpl` ConfigMap and the Alertmanager config Secret, so
`fields[].value`, `fallback` and the four button URLs — which live in the
receiver YAML rather than the `.tmpl` — are exercised too. Then per fixture:

```
amtool template render --template.glob=<extracted.tmpl> \
  --template.text='<each templated field from the rendered receiver>' \
  --template.data=scripts/alertmanager-fixtures/<case>.json
```

Five fixtures: `critical-single`, `warning-group-of-3`, `resolved`,
`mixed-firing-resolved`, and `degenerate` — no namespace, no summary, no
`runbook_url`, empty `cloud`.

Assertions: exit 0, and output containing none of `<no value>`, a literal `${`,
or `%!`. Output is **golden-compared** against committed `.txt` files, so any
future change to the wording appears as a readable diff in review.

Wired as a new step inside `validate-manifests.sh`, which owns the bundle the
script reads, keeping CI's single entry point single.

## Files touched

| File | Change |
|---|---|
| `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` | externalLabels; `monzoTemplate.enabled: false`; `templateFiles.ogenki.tmpl`; receiver `fallback`/`fields`/`actions`; per-severity routes; `inhibit_rules` |
| `opentofu/aws/eks/configure/kubernetes.tf` | `cloud = "aws"` |
| `opentofu/gcp/gke/configure/kubernetes.tf` | `cloud = "gcp"` |
| `scripts/flux-schema/render-bundle.py` | `"cloud"` fixture |
| 7 VMRule files | `message:` → `summary:` (19 occurrences) |
| `scripts/validate-vmrules.sh` | summary gate |
| `scripts/validate-alertmanager-templates.sh` | new |
| `scripts/alertmanager-fixtures/*.json`, `golden/*.txt` | new |
| `scripts/validate-manifests.sh` | wire the new step |
| `mise.toml` | `alertmanager = "0.32.1"` |
| `website/content/docs/decisions/0037-alertmanager-native-slack-templates.md` | new ADR |
| `website/content/docs/platform/observability/dashboards-and-alerts.md` | annotation contract + rendered example |

## Risks

| Risk | Handling |
|---|---|
| A template parse error silently kills **every** notification | The amtool gate is the mitigation, and the reason it renders the real config rather than the source |
| `cloud=""` if manifests merge before the two `configure` applies | Template guards with `with`; PR body states apply-first |
| New external labels change alert fingerprints | A one-time re-notify burst on rollout — stated in the PR rather than discovered in Slack |
| Chart bumps Alertmanager past the pinned `amtool` | The gate fails loudly on a template the pinned binary cannot parse, which is the risk worth catching |

## Alternatives rejected

- **Block Kit through a bridge** (Robusta, or a custom webhook relay).
  Alertmanager [has no Block Kit support](https://github.com/prometheus/alertmanager/issues/2217)
  and the issue has been open since 2020. A bridge would add a component to the
  data path and duplicate RunLore's existing Slack integration for formatting
  alone. Recorded in ADR-0037.
- **A channel per severity, per cluster, or per environment.** Rejected in
  favour of one channel carrying better messages; both clusters are `env=dev`
  today, so a split by environment would be a no-op and a split by cluster grows
  a channel per cluster forever.
- **Moving long `description` prose into runbook pages.** The prose is what
  RunLore reads. Truncation belongs in the presentation layer, not the rule.

## Out of scope

- Writing runbook pages for the 13 alerts without a `runbook_url`.
- Threading RunLore investigations under the originating alert message. Both
  post to `#alerts` with the same Slack app, so correlation is possible, but it
  needs a RunLore-side feature and belongs in its own design.
- Alert rule thresholds and coverage. This design changes how alerts are
  *presented*, not which ones exist.
