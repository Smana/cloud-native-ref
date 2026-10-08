# Agent observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On aws-0, a human opens any `AgentRun` from an "Agent fleet" Grafana page and lands on its
"Agent run" page. That page shows where the run stands, its step log and gateway calls, its tokens,
cost and latency, and one trace per run in VictoriaTraces that carries metadata only.

**Architecture:** Nothing new runs in the sandbox. The harness's OpenHands SDK exports OTLP/HTTP
spans (Laminar, env only), and agent-router's Envoy exports OTLP/gRPC spans. Both go to a new
OpenTelemetry Collector, `agent-traces-collector` in `observability`, which is the only path into
VictoriaTraces. On the sandbox path the collector:
- drops the run id the span carries;
- stamps the sending pod's `agents.ogenki.io/run-id` label;
- drops every span that no run sent;
- keeps an allowlist of metadata attributes and nothing else.

kube-state-metrics turns `AgentRun` status into `agentrun_*` series, and two `GrafanaDashboard` CRs
join those series with VictoriaLogs, the gateway's `gen_ai_*` metrics and VictoriaTraces.
`task agent:run` prints the run's page on stderr, and `kubectl get agentrun` gains four columns.

**Tech Stack:**
- OpenTelemetry Collector `otel/opentelemetry-collector-k8s` 0.160.0, chart `opentelemetry-collector` 0.173.1 (processors `k8s_attributes`, `transform`, `filter`, `redaction`);
- Envoy Gateway 1.9.1 `EnvoyProxy.spec.telemetry.tracing`;
- kube-state-metrics 2.19.1 (subchart 7.5.3 of `victoria-metrics-k8s-stack` 0.93.0), custom-resource state;
- VictoriaTraces v0.11.0 (`victoria-traces-single` 0.1.11), VictoriaLogs, VictoriaMetrics;
- grafana-operator `GrafanaDashboard`;
- OpenHands SDK 1.49.6 with `lmnr` 0.7.60, in harness `v0.1.0-pr2110.29b5f228`;
- Crossplane v2 + function-kcl (the `AgentRun` composition); Cilium CNP with L7 HTTP rules.

**Spec:** [`docs/superpowers/specs/2026-09-27-agent-observability-design.md`](../specs/2026-09-27-agent-observability-design.md)
(binding, on `main`; read it whole before any task). Also read:
- the [programme design](../specs/2026-09-23-agent-factory-design.md), whose C1–C7 bind every task;
- the SP1 design and plan (what this slice sits on, as built on `integration/agent-factory`);
- the SP2 plan's header, Global Constraints, PR map, rulings P33–P40 and Phase 0.5 (the stacking model and H-1, which this slice stacks on);
- the SP3 plan's Task 8.7, which this plan takes over (ruling O8).

## Global Constraints

- **Target** aws-0 only, like SP1 and SP2. gcp-0 gets the shared kube-state-metrics config (O11)
  and nothing else.
- **GCP parity cross-plan edit (2026-09-29).** Every child O-1 adds to
  `clusters/aws-0-agent-platform/` (the collector and the rest) gets its twin in
  `clusters/gcp-0-agent-platform/`, with `gke-gcp-0-vars` and a `*/gcp-0/*` overlay when it
  substitutes, under the same rule as SP2's [Cross-plan edits](2026-09-29-gcp-parity-plan.md#cross-plan-edits).
- **Owner decisions, 2026-09-27.** Traces carry metadata only: timing, model, token counts, tool
  names, status and errors. No prompts, completions or tool output. Build now, on SP1, before SP2.
- **Metadata only is enforced outside the sandbox.** The collector is the control, and SO-3 is
  proved on what VictoriaTraces stores. The harness env is hygiene only (O6).
- **Names.**

  | Thing | Value |
  |---|---|
  | Collector | HelmRelease `agent-traces-collector` (release `agent-traces`) in `observability`; Service, ServiceAccount and pod label `app.kubernetes.io/name: agent-traces-collector` |
  | Collector ports | `4318` OTLP/HTTP from run pods (`POST /v1/traces` only) · `4317` OTLP/gRPC from agent-router · `8888` metrics · `13133` health |
  | Collector FQDN | `agent-traces-collector.observability.svc.cluster.local` |
  | VictoriaTraces insert | `http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces` |
  | Span attribute and resource attribute | `agent.run_id` (the runId, 8 chars of `[a-z2-7]`), set by the collector only |
  | Service names | `agent-harness` (set by the collector), `agent-router` (EnvoyProxy `serviceName`) |
  | Envoy span tag | `agent.principal` = `%REQ(X-AR-AGENT)%` = `system:serviceaccount:agents:xplane-run-<runId>` |
  | KSM metrics | `agentrun_info`, `agentrun_status_phase`, `agentrun_outcome_info`, `agentrun_usage_tokens`, `agentrun_budget_max_tokens`, `agentrun_started_timestamp_seconds`, `agentrun_finished_timestamp_seconds`; every series carries `run_id` |
  | Dashboards | "Agent run" `uid: agent-run` (variable `run`), "Agent fleet" `uid: agent-fleet`, both in folder `agents`; "Agent platform" (`uid: agent-platform`) unchanged |
  | Run page URL | `https://grafana.${private_domain_name}/d/agent-run/agent-run?var-run=<runId>` (SP2, SP3 and `task agent:run` link to it) |
  | ADR | **0051**, the next free number (0041–0050 are taken or reserved by SP1–SP4) |

- **Pins**, resolved 2026-09-27 and re-resolved on the day of the task that introduces them:
  - `otel/opentelemetry-collector-k8s:0.160.0@sha256:76d7a04f2291da1d8b7ce259468d09f0f9f44f71f67a5737539f64ca82b5bdb1`
    (index digest: `skopeo inspect --raw docker://docker.io/otel/opentelemetry-collector-k8s:0.160.0 | sha256sum`);
  - chart `opentelemetry-collector` `0.173.1` from `https://open-telemetry.github.io/opentelemetry-helm-charts`.

  Component names are the 0.160 ones: `k8s_attributes` and `otlp_http`, which the chart's own
  `rewriteDeprecatedComponentNames` would produce anyway.
- **No merge, no release tag before the owner's UX sign-off** (SP2 ruling P33, which binds this
  slice).
  - One stack per repo, merge-only, never rebased. Each PR is based on the previous open branch of
    its repo (PR map).
  - Live gates run on `integration/agent-factory`, with CI pre-releases pinned by digest and
    `XRD_CRDS_FILE` from `./scripts/ci/fetch-xrd-crds.sh` (H-1, SP2 P40).
  - The crossplane-configuration pre-release is named after the PR's **synthetic merge commit**:
    copy it from the CI job summary, never derive it from a SHA.
  - Crossplane never upgrades an installed dependency. Patch the core package by hand during the live check:
    `kubectl patch configuration.pkg.crossplane.io smana-crossplane-configuration-core --type merge -p '{"spec":{"package":"ghcr.io/smana/crossplane-configuration-core:<pre-release>"}}'`.
- **Flux substitution.** `observability/base/agent-platform/` and `infrastructure/base/agent-router/`
  are applied with `postBuild.substituteFrom`, so every literal `${…}` in them is written `$${…}`. That
  covers the collector's `$${env:MY_POD_IP}` and the dashboards' `$${run}`, `$${datasource}` and
  `$${__value.text}`. Bare `$__range`, `$__rate_interval` and `$1` pass through Flux untouched (repo
  convention). `python3 scripts/ci/flux-schema/check-substitution.py` fails on an unescaped
  `${var}` that the vars ConfigMap lacks.
- **Constitution on the collector.** Default-deny CNP; requests and limits; liveness, readiness and
  startup probes; restricted securityContext with `seccompProfile: RuntimeDefault`; RBAC least
  privilege, which here means a `Role` on pods in `agents` only. Nothing permanent is applied with
  `kubectl`, and live probes are torn down in the same task.
- **C1, opt-in.** The collector, its RBAC and CNP, both new dashboards and the EnvoyProxy tracing live
  under the `agent-platform` umbrella (suspended by default). The HelmRepository source and the
  kube-state-metrics config are always on (O11).
- **H-1 owns the step-log token redaction (M4).** This plan does not touch `agent_run.py`'s
  redaction, and changes the harness at all only under ruling O13.
- **Evidence.** No "done / passing" without a command run in the same response and its output cited.
  - This repo: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
    → exit 0, `Invalid: 0, Skipped: 0`, then `./scripts/ci/validate-links.sh`,
    `python3 scripts/ci/flux-schema/check-substitution.py`, `./scripts/ci/verify-doc-paths.sh` and
    `task check` → exit 0.
  - crossplane-configuration: `task check` → exit 0.
- **Git.**
  - Each PR starts in a fresh worktree on its stack parent (PR map).
  - Merge the parent and `origin/main` in before each push; never rebase.
  - Conventional commits in English, with no `Co-Authored-By` trailer and no generated-with line.
  - `ship-it`'s simplify, prune, gates and review apply; its merge does not (P33).

**Markers used below.** **[LIVE]** needs aws-0 rebuilt from an `integration/agent-factory` checkout,
with this slice merged in and both umbrellas unsuspended there. **[OWNER]** is an action only the
owner can take; the executor stops and asks.

---

## Pre-flight rulings

Where the spec is silent, ambiguous, or contradicts upstream as verified, this plan rules. None edits
the spec; the rulings worth promoting into it are repeated in [Spec deltas proposed](#spec-deltas-proposed).

| # | Ruling | Why | Cost if wrong |
|---|---|---|---|
| O1 | The run CNP admits **`POST /v1/traces` on the collector's :4318** and nothing else in `observability`. VictoriaTraces is never reachable from a sandbox. SO-4 is proved on that path, as Δ1 words it | The spec's security section makes the collector the control. A direct path to VictoriaTraces' insert endpoint, which SO-4's wording names, would let a compromised run skip the filter | None: the spec's intent. SO-4 adds "VictoriaTraces' :10428 is `DROPPED`" |
| O2 | The collector keeps an **allowlist** (`redaction` processor, `allow_all_keys: false`) over resource, scope, span and span-event attributes, instead of the spec's denylist | At lmnr 0.7.60 content lives in `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.tool.definitions`, `lmnr.span.input`, `lmnr.span.output` and `llm.headers` (Task 0.1). None of them matches the spec's `gen_ai.prompt*`/`gen_ai.completion*`, so a denylist fails open on the next rename. The processor fails closed, and it covers resource, scope, span and event attributes (`processor.go`, v0.160.0) | A useful new metadata key is dropped until it is added to the list |
| O3 | `otel/opentelemetry-collector-k8s` 0.160.0 through chart 0.173.1, configured with **`alternateConfig`**, with no presets and no `clusterRole` | The k8s distribution ships exactly `otlp`, `k8s_attributes`, `transform`, `filter`, `redaction`, `memory_limiter`, `batch`, `otlp_http`, `debug` and `health_check` (`otelcol-k8s components`, run 2026-09-27). The `kubernetesAttributes` preset puts `k8s_attributes` first, ahead of the strip step. It also matches pods by the spoofable `k8s.pod.ip` and `k8s.pod.uid` resource attributes. `alternateConfig` drops the chart's default jaeger, zipkin and prometheus receivers | A chart bump must re-check `alternateConfig` semantics |
| O4 | The run id comes from the **connection only**. The collector deletes any client-supplied `agent.run_id`, `agent.role`, `k8s.pod.name` and `k8s.namespace.name` first, then runs `k8s_attributes`, then **drops every span with no resolved run id** | `k8s_attributes` never overwrites a present key (`setResourceAttribute`, v0.160.0), so "overwriting the span's own" (spec) needs the delete first. `pod_association` from `connection` is the only source a run cannot forge | If Cilium's L7 proxy hides the pod IP from the collector, every span is dropped. Task 3.1 checks it, and Task 0.4 names the fallback |
| O5 | **Two receivers and two pipelines.** `otlp/agents` (HTTP :4318) carries the sandboxes' spans through the filter. `otlp/router` (gRPC :4317) carries agent-router's without it | Envoy Gateway 1.9.1 exports OTLP/gRPC only (Task 0.2), and every attribute on those spans is set by our `EnvoyProxy` manifest, not by a sandbox | A sandbox that reached :4317 would skip the filter. The run CNP never admits it, and SO-4 checks that |
| O6 | Harness hygiene is **partial**: `LMNR_INSTRUMENTS=openai` and `LMNR_TRACE_CONTENT=false`, with no in-sandbox content filter | lmnr 0.7.60 hardcodes `enable_content_tracing = True` (`opentelemetry_lib/__init__.py`). The SDK's `@observe` spans record `lmnr.span.input` and `lmnr.span.output` with no switch. `openai` is the one instrument that honours `LMNR_TRACE_CONTENT` and injects `traceparent` (Task 0.1). A span filter inside agent-server would monkeypatch lmnr internals | Content crosses the pod network (WireGuard on aws-0) to the collector and is never stored. If the owner wants it never to leave the pod, that is a harness follow-up |
| O7 | On SP1, **tokens vs budget** reads the gateway counter `gen_ai_client_token_usage_sum{ar_agent=…}`, with `status.usage.tokens` beside it once a meter writes it. **PR** reads `status.pullRequest`, and the run page also links the branch's pull-request search | On SP1 nothing writes `agents.ogenki.io/usage-tokens` or `/pull-request`: those come from SP3's factory and SP4 PR 2's meter (SP1 plan, "Status has one writer") | The two token numbers can differ slightly. SO-1's PR proof annotates by hand, as runbook 07 does. The TOKENS and PR columns stay empty until SP3 and SP4 |
| O8 | **The printer columns move here from SP3's CC-F1 (SD13)**: PRINCIPAL `.spec.principal`, PR `.status.pullRequest`, TOKENS `.status.usage.tokens`, REASON `.status.reason` | The spec moves them. `.spec.principal` exists on every run since SP1, while SP3's `agents.ogenki.io/principal` label exists only on factory runs | SP3 Task 8.7 is dropped ([Cross-plan edits](#cross-plan-edits)). The label stays useful for `kubectl get -l` |
| O9 | "Agent fleet" is a **new** dashboard, `uid: agent-fleet`. "Agent platform" stays unchanged as the capacity view that the M9 `dashboard` annotations link to | The alerts already link `/d/agent-platform`, and SP2 and SP3 add their own dashboards beside it | Two pages instead of one, linked both ways |
| O10 | The dashboards live in the existing `agents` folder with **Grafana's default permissions**, which every SSO Viewer has | Grafana OSS has no team sync, and `role_attribute_path` makes every SSO user a Viewer. Any Viewer already reads the same data in Explore, so a folder ACL would hide the page, not the data. `agents-member` does not exist before SP2's S2 | Developers outside the agent groups read run metadata. The metadata-only decision is what makes that acceptable |
| O11 | kube-state-metrics' custom-resource state goes into the shared `vm-common-helm-values`, which both clouds read, and not under the agent umbrella | The spec names the stack's single KSM (Task 0.3). The `AgentRun` CRD ships in the always-on Crossplane package, and KSM discovers CRDs itself. With no runs there are no series | A read-only list/watch on `agentruns` in a cluster that runs no agents |
| O12 | **Stacking.** O-1's *Base* is `feat/gcp-agent-platform` (GCP parity G-5), itself on H-1 (GCP parity cross-plan edit, 2026-09-29; was `fix/agent-review-hardening` directly). CC-O1 stacks on CC-H1 (`ci/prerelease-xrd-crds`). SP2's CC-S1 must then stack on CC-O1, and SP2's S1 should stack on O-1 | Integration pins one crossplane-configuration package, so that stack must be linear. S1 and O-1 both edit `agent-run.sh`, its test and the agent-platform kustomization | SP2 Phase 1 starts after O-1 and CC-O1 exist. Those are the SP2 plan edits under [Cross-plan edits](#cross-plan-edits) |
| O13 | *(Superseded by O21, 2026-09-29: Task 0.5 verified the loss, so the harness change is no longer conditional.)* A harness change is made **only if Task 3.3 loses the root span**. It lands in O-1 as harness source `v0.1.2`: `agent_run.py` waits 25 s instead of 10 for agent-server's shutdown. It is not made on `feat/agent-harness` | `feat/agent-harness` sits below #2111 and H-1 (whose source is `v0.1.1`, M4). A change there would be merged up two branches and would re-pin SP1's CC-2 | H-S3 must then stack on O-1 to ship it in `v0.2.0` |
| O14 | agent-router's spans are found by the Envoy tag **`agent.principal`**, not by a derived `agent.run_id` | Deriving the run id needs a regex replacement with `$1`, which crosses Flux's and the collector's `$` escaping. The principal already names the run. `traceparent` puts these spans in the harness trace anyway: the harness sends one (Task 0.1), and Task 3.3 checks it survives identity-proxy | The router search uses a longer tag value |
| O15 | **ADR-0051** records the collector as the agent trace gate | The repo rule: rejected alternatives exist. Filtering inside the sandbox, exporting straight to VictoriaTraces, and Vector's OTLP source (ADR-0030) were all rejected. It also reverses SPEC-006 CL-1's "no collector" for this path | One ADR task |
| O16 | **No alert** for the collector, and none per run | The spec puts per-run alerts out of scope (SP3 owns alerting). A stalled collector loses traces and leaks nothing. The fleet page shows accepted, refused, exported and failed spans | A stalled trace pipeline is noticed on the page, not paged |
| O17 | `task agent:run` prints `agent-run: dashboard <url>` on **stderr** after the create, with no link on `--dry-run` or when no host is found. The host is `AGENT_GRAFANA_URL`, else `https://` + the `grafana` HTTPRoute's first hostname. `from` is the create time minus a minute, `to=now` | SO-5's contract (the name is the last stdout line), cloud-neutral | One extra `kubectl get` per run |
| O18 | `exception.message` and `exception.stacktrace` are dropped. `exception.type` and the span status stay, the status message capped at 128 characters, and every kept string attribute at 256 | An exception message can echo tool output. The step log beside the trace carries the error text, 400 characters and M4-redacted | A trace alone does not say why a call failed |
| O19 | The harness gets the **base** `OTEL_EXPORTER_OTLP_ENDPOINT=http://…:4318` and `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`, not the spec's `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | lmnr's log exporter reads the same `ENDPOINT` key, TRACES first. With a traces URL, any OTel log record would be POSTed to `/v1/traces`, which the run CNP admits, and only the collector's decoder would stand in the way. With a base URL, lmnr appends `/v1/traces` and `/v1/logs` itself (`_normalize_http_endpoint`), and the run CNP drops `/v1/logs`. Re-run 2026-09-27 with the base URL: the same 7 spans, 1 trace, `traceparent` present | None found |
| O20 | The collector's :4317 is the **platform port**: it takes agent-router's spans and, from SP3, the factory's task spans (`agent-system`, `app.kubernetes.io/name: agent-factory`), both through the unfiltered `traces/router` pipeline (Task 2.2a) | Both writers are platform code whose attributes this repo reviews. The factory's task span carries ids and an end reason, never issue text | A sandbox on :4317 would skip the filter. The run CNP never admits it (SO-4), and the collector CNP admits only those two peers |
| O21 | **The harness roots each run's trace** (Task 2.8a, harness `v0.1.2` in O-1). An `agent-run` span is parented on the pod's `TRACEPARENT` when it is a valid W3C header; the composition projects it from the claim annotation `agents.ogenki.io/traceparent`, which SP3's factory writes (R46; Task 1.3a). Otherwise the run starts a fresh trace, which is the `task agent:run` path. agent-server's own root span becomes its child through lmnr's `LMNR_SPAN_CONTEXT`. Before stopping agent-server, the harness closes the conversation and waits 2 s at a 1 s batch. **This supersedes O13's condition**: the loss is verified (Task 0.5), so Task 3.6 is replaced by Task 2.8a | Task 0.5 (2026-09-29) found three things. `LMNR_SPAN_CONTEXT` puts every agent-server span, the root included, in the given trace under the given parent. agent-server exports nothing at exit: SIGTERM after a 2 s conversation exported 0 spans. Its root span ends only when the conversation closes: without the DELETE, the root span was missing. `agents.ogenki.io/traceparent` clashes with none of SP1's annotations (`revoked`, `usage-tokens`, `pull-request`, `finished-phase`, `principal`) or SP3's (`stop`, `revert`) | SP2's H-S3 must stack on O-1 to ship this in `v0.2.0` (Cross-plan edits). A run adds a 2 s pause and one DELETE after its conversation ends; SP2's bridge has mirrored the final events by then (P5, 1 s poll) |
| O22 | **The trace id is correlation only, never identity.** Step-log lines gain `| trace_id=<32 hex>` (Task 2.8a), and the run page turns it into a "View Trace" link through the VictoriaLogs datasource's existing `log.trace_id` derived field (Task 2.6a). Attribution stays on `x_ar_agent` (agent-router's verified sub) and on the `agent.run_id` the collector stamps from the connection (O4) | A sandbox controls the trace id it prints, the spans it sends and the `traceparent` on its requests, so all three are untrusted. Nothing meters, authorizes, attributes or joins by it except a link a human clicks | A run can print another run's trace id, which misplaces a link but reveals no content. The run page's panels still filter on the pod and principal |
| O23 | **The tier reaches the metrics through kube-state-metrics**: `agentrun_info` gains `tier`, from the claim label `agents.ogenki.io/tier` that SP3 writes (R47; Task 2.5a). The fleet page compares tier with tokens and steps, and the run page shows the tier (Tasks 2.6a, 2.7a) | The tier is not `spec.model`: every tier maps to `agent-default` until SP4 PR 2 (SP3 R11). The gateway's labels carry the model, not the tier. A reviewer runs on another tier than its task (SP3 Task 4.2), so the task's tier is not the run's | Runs created by `task agent:run` carry no tier and show an empty cell |
| O24 | **A run's tier is fixed; agents are never re-routed per request within a run** (SP3 R47). The fleet panels read one tier per run | Mid-run re-routing would split a conversation across models and invalidate the provider's prompt cache. `spec.model` is already immutable (XRD CEL), and agent-router routes on the model name | None here: the panels would under-report a re-routed run, which R47 forbids |

**Residuals, not fixed here.** VictoriaTraces' own insert path stays reachable from the tailnet
(`vt.${private_domain_name}`, HTTPRoute `victoria-traces`) and from in-cluster pods outside
`agents`. Those are trusted writers, not sandboxes, and narrowing that route to `/select` is a
separate change to shared observability. A run can also send a `traceparent` that collides with
another run's trace id, which misplaces router spans (metadata) but reveals no content.

## Spec deltas proposed

| Δ | Spec says | Proposed | Ruling |
|---|---|---|---|
| Δ1 | SO-4: "admits traces to VictoriaTraces' insert path only" | "admits `POST /v1/traces` on the collector's :4318 only; another path, another port, and VictoriaTraces' :10428 are `DROPPED`" | O1 |
| Δ2 | The collector "drops `gen_ai.prompt*`, `gen_ai.completion*` and tool input and output attributes" | "keeps an allowlist of metadata keys and drops every other resource, span and event attribute" | O2 |
| Δ3 | "the harness also records no content attributes" | Not achievable by configuration at SDK 1.49.6 and lmnr 0.7.60. Content stays in `lmnr.span.input/output` and reaches the collector, which drops it | O6 |
| Δ4 | "agent dashboards in a folder readable by `agents-member`" | "in the `agents` folder, readable by every Grafana Viewer, the same audience as the data in Explore" | O10 |
| Δ5 | Unverified row 2, fallback "gateway spans skipped" | Resolved: EG 1.9 exports OTLP/gRPC only, and the collector's gRPC receiver takes it | O5 |
| Δ6 | Status panel "tokens used vs `maxTokens`", "PR link" | On SP1: gateway tokens, and the branch's PR search. `status.usage.tokens` and `status.pullRequest` once SP3 and SP4 write them | O7 |
| Δ7 | Traces row: "`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`" | "`OTEL_EXPORTER_OTLP_ENDPOINT` (the collector's base URL), so that no other OTLP signal can use the traces path" | O19 |
| Δ9 | SO-3 "A run produces one trace" | "A run started by `task agent:run` produces one trace rooted at its `agent-run` span. A factory run's spans form a subtree of its task's trace, rooted at the factory's task span" | O21, SP3 R46 |
| Δ10 | Logs row: the step log `agent-run step N: <tool> \| <summary> \| <target>` | "…`\| trace_id=<hex>` when tracing is on: a link to the trace, correlation only" | O22 |

## Cross-plan edits

**SP3 plan** (`2026-09-27-agent-dark-factory-plan.md`). The one-line edit replaces the whole
Task 8.7 section (its heading through its "Merge order" bullet) with:

```markdown
### Task 8.7: moved to the observability plan (CC-O1 ships the `AgentRun` printer columns, ruling O8)
```

The same pass drops what points at CC-F1:
- the PR-map row `CC-F1`;
- the file-structure row for `apis/agentrun/definition.yaml (CC-F1)`;
- the owner-action clause "(CC-F1 merged inside SP2's 7.4, after CC-S5 and before its tag)";
- "CC-F1's `AgentRun` printer columns (SD13) ride along" in the Phase 8 intro;
- Task 10.4 Step 0;
- `feat/agentrun-printer-columns` in Task 10.x's branch deletion;
- in the Produced table, "CC-F1's printer columns (SD13)", which becomes "the observability plan's printer columns";
- the SD13 decision row, which becomes "moved to the observability plan (CC-O1)", and the summary row's "SD13 accepted as CC-F1".

**SP2 plan** (proposed, O12):
- the PR-map row CC-S1's *Base* becomes `feat/agentrun-observability` (CC-O1), and its *Needs* gains CC-O1;
- row S1's *Base* becomes `feat/agent-observability` (O-1);
- Phase 7's wave merges CC-O1 right after CC-H1 and O-1 right after H-1;
- H-S3's *Base* becomes `feat/agent-observability`, and Task 7.3 merges it after O-1. This was
  conditional on O13 and is now required by O21: O-1 carries harness source `v0.1.2`.

**SP3 plan, further review (2026-09-29):**
- Task 1.5a: `runs.Spec` gains `Traceparent` and `Tier`;
- Task 1.10b: the task's root span;
- Task 1.12a: the factory's config and its egress to :4317;
- Task 1.13a: [LIVE];
- Task 4.2a: a reviewer's own tier;
- rulings R46 and R47.

They need this plan's Tasks 1.3a, 2.2a and 2.8a on the integration branch.

S1's `--room` edit to `agent-run.sh` keeps O-1's dashboard line after its own changes.

## Interfaces with other sub-projects

**Consumed (SP1 as built on `integration/agent-factory`, plus H-1):**

| Name | What this plan relies on |
|---|---|
| `AgentRun` XRD (`cloud.ogenki.io/v1alpha1`, ns `agents`) | `spec.principal`, `spec.role`, `spec.dataClass`, `spec.repository`, `spec.model`, `spec.budget.maxTokens`; `status.phase` (enum `Pending`, `Running`, `Succeeded`, `Failed`, `BudgetExhausted`, `Revoked`), `status.runId`, `status.branch`, `status.startedAt`, `status.finishedAt`, `status.reason`, `status.pullRequest`, `status.usage.tokens`; the existing printer columns Role, Class, Phase, Branch |
| Run pod | Named `xplane-run-<runId>` in `agents`, labels `agents.ogenki.io/run-id` and `agents.ogenki.io/role`, container `harness`. Its env reaches agent-server (`server_env` copies `os.environ`) |
| Step log | stdout lines `agent-run step N: …`, `agent-run message: …`, `agent-run error: …`, `agent-run summary: N steps` (H-1 redacts tokens in them) |
| agent-router access log | JSON, stored as `log.*` at ingest. `log.x_ar_agent` is the verified sub. `log.path` is the **post-rewrite** path, so an accepted model call logs `/api/paas/v4/chat/completions` (runbook 02 correction) |
| Gateway metrics | `gen_ai_client_token_usage_sum{ar_agent, gen_ai_token_type, gen_ai_request_model}`, `gen_ai_server_request_duration_seconds_{bucket,count}{ar_agent, error_type}`, and `llm_gateway:price_usd_per_mtoken{gen_ai_request_model, gen_ai_token_type}` (ai-gateway umbrella, which agent-platform depends on) |
| `scripts/ci/fetch-xrd-crds.sh` (H-1, B2) | The XRD CRDs of a pinned crossplane-configuration pre-release |
| Grafana datasource `VictoriaTraces` | `type: jaeger`, uid pinned `VictoriaTraces`. Jaeger tag search maps a key to `span_attr:<key>` unless it is prefixed `resource_attr:` (VictoriaTraces v0.11.0 `jaeger.go`) |

**Produced:**

| Name | Where | Consumer |
|---|---|---|
| Run page URL `…/d/agent-run/agent-run?var-run=<runId>[&from=<ms>&to=now]` | Grafana | `task agent:run` (SO-5); SP2's room UI; SP3's issue narration |
| "Agent fleet" `uid: agent-fleet` | Grafana | SP2 and SP3 add their own panels or link to it |
| `agentrun_*` series with `run_id` | VictoriaMetrics | Dashboards; SP3's VMRules may use them |
| `agent.run_id` on every harness span | VictoriaTraces | Grafana's Jaeger search |
| Printer columns PRINCIPAL, PR, TOKENS, REASON | `AgentRun` XRD | `kubectl get agentrun` (SP3's SD13) |

## PR map

`CC-*` is `Smana/crossplane-configuration`, `O-*` this repo. **Nothing merges before the owner's UX
sign-off** (P33). Each PR is based on its *Base*: merge-only, never rebased.

| # | Repo · branch | Base (stack parent) | Needs | Carries | Live gate (aws-0) |
|---|---|---|---|---|---|
| CC-O1 | crossplane-configuration · `feat/agentrun-observability` | `ci/prerelease-xrd-crds` (SP2 CC-H1, on SP1 CC-2 `feat/agentrun-harness` @ `d9c4449`) | CC-H1 open | Run CNP: DNS name and L7 egress to the collector's `POST /v1/traces`; harness OTEL env; printer columns | via O-1 |
| O-1 | this · `feat/agent-observability` | `feat/gcp-agent-platform` (GCP parity G-5, itself on SP2 H-1 `fix/agent-review-hardening`, on SP1 PR 6 `feat/agent-e2e` #2111) (GCP parity cross-plan edit, 2026-09-29; was `fix/agent-review-hardening` directly) | H-1 open; CC-O1's pre-release | ADR-0051; the collector (HelmRepository, HelmRelease, Role, CNP, scrape); agent-router tracing and data-plane egress; KSM `AgentRun` state; the two dashboards; `agent-run.sh` stderr link; runbook 08 steps; the CC-O1 pin; harness `v0.1.2` (Task 2.8a, O21) | SO-1…SO-5 on gcp-0, after GCP parity Task 8.6 (Phase 3) |

**Neither base exists yet.** H-1 and CC-H1 are SP2's Phase 0.5, which runs first. This plan's Phase 0
spikes need neither and can run today.

**Live-check routine for O-1 (the "branch cluster"):**
1. Merge O-1 into `integration/agent-factory` with a merge commit, never a rebase. O-1 already pins
   CC-O1's pre-release in `configuration-packages.yaml`. The App Wizard's clone tag stays on `v0.7.1`.
2. Hand-patch the core package to the same pre-release (Global Constraints).
3. `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh` → `Invalid: 0`.
4. Wait for Ready, one name per call: `flux get kustomization observability -n flux-system`, then
   `agent-router`, then `agent-observability`.
5. Run runbook 08 Steps 6–10 (Task 2.9 writes them). Tear down every probe in the same task.

**Merge order in the programme's wave** (P33 Phase 7):
- crossplane-configuration: CC-2 → CC-H1 → **CC-O1** → CC-S1 → …, one release tag at the end;
- this repo: #2111 → H-1 → **O-1** (re-pinned to that release) → S1 → ….

After its live gate, O-1 leaves draft and stays open until the wave.

## File structure

**`Smana/crossplane-configuration` (CC-O1)**

| Path | Responsibility |
|---|---|
| `apis/agentrun/kcl/main.k` | `_TRACES_FQDN` in the DNS allowlist; one egress rule to the collector's `POST /v1/traces`; four OTEL/Laminar env vars on the harness |
| `apis/agentrun/kcl/main_test.k` | Two tests: the egress rule and the env |
| `apis/agentrun/definition.yaml` | Four printer columns |
| `apis/agentrun/kcl/README.md` | The CNP row names the trace egress |
| `tests/golden/agentrun-basic.yaml`, `tests/golden/agentrun-complete.yaml` | Re-rendered |

**This repo (O-1)**

| Path | Responsibility |
|---|---|
| `flux/sources/helmrepo-open-telemetry.yaml` | HelmRepository `open-telemetry` in `observability` |
| `observability/base/agent-platform/agent-traces-collector.yaml` | HelmRelease (the filter), Role and RoleBinding in `agents`, CNP, VMServiceScrape |
| `observability/base/agent-platform/grafana-dashboard-agent-run.yaml` | "Agent run" |
| `observability/base/agent-platform/grafana-dashboard-agent-fleet.yaml` | "Agent fleet" |
| `observability/base/agent-platform/kustomization.yaml` | The three new files |
| `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` | `kube-state-metrics:` custom-resource state for `AgentRun` |
| `infrastructure/base/agent-router/envoyproxy.yaml`, `network-policy-data-plane.yaml` | OTLP/gRPC tracing to the collector; the data plane's egress to :4317 |
| `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` | CC-O1's pre-release pin |
| `scripts/ops/k8s/agent-run.sh`, `scripts/ci/tests/test-agent-run.sh` | The stderr dashboard link (SO-5) |
| `scripts/ci/tests/test-agent-observability.py` | Real-tree suite: collector, router, KSM, dashboards |
| `scripts/ci/tests/test-agent-traces-filter.sh` | The collector's filter, run in Docker against a content-bearing fixture |
| `website/content/docs/decisions/0051-otel-collector-agent-trace-gate.md`, `_index.md` | ADR-0051 |
| `clusters/aws-0-agent-platform/README.md` | The `agent-observability` row |
| `docs/runbooks/agent-factory/08-observability.md` | Steps 6–10: the live gate, repeatable |
| `container-images/agent-harness/{agent_run.py,Dockerfile,tests/test_agent_run.py}` | Harness `v0.1.2`: the run's root span, `LMNR_SPAN_CONTEXT`, `trace_id` on step lines, the close before the stop (Task 2.8a, O21) |

## Success criteria → proving task

| SC | Offline | Live | How |
|---|---|---|---|
| SO-1 fleet → run page with phase, reason, PR, tokens vs budget | 2.6, 2.7 (suite) | **3.5** | Fleet and run-page queries through the VM proxy for run A; [OWNER] one click |
| SO-2 step log and gateway calls of that run only | 2.6 | **3.5** | With run B live beside A, A's step-log and gateway queries return only A's pod and principal |
| SO-3 one trace, a span per model call, no prompt or completion in any attribute | 0.1, 0.4, **2.3** | **3.3** | One trace id; `llm.*` span count equals accepted model calls; marker sweep = 0; attribute keys ⊆ allowlist; `redaction.redacted.count > 0` |
| SO-4 CNP admits the traces path only | 1.2 | **3.4** | From inside run B: `/v1/traces` 200, `/v1/logs` 403, :4317 and VictoriaTraces blocked; Hubble `FORWARDED`/`DROPPED` |
| SO-5 link on stderr, name last on stdout | **2.8** | **3.2** | `task agent:run … 2>err | tail -1` is the name; `err` holds the link |

## Owner actions

| Marker | Task | What |
|---|---|---|
| [OWNER] | 3.1 | gcp-0, after GCP parity Task 8.6 (GCP parity cross-plan edit, 2026-09-29; was "the next aws-0 rebuild"), from an `integration/agent-factory` checkout with O-1 merged in. This is the same rebuild as SP2's Task 0.5.14 |
| [OWNER] | 3.5 | One look at the two dashboards: Grafana is SSO-gated, so no agent can open them headlessly (runbook 08 correction) |
| [OWNER] | 3.6 | Only under O13, and only if the session's gh token lacks `write:packages`: push the harness pre-release |
| [OWNER] | — | The programme's UX sign-off (P33) before any merge |

---

## Phase 0 — Spikes (offline, before any branch)

Gate: each spike records its outcome in its task, and in O-1's PR body under "Spikes". Tasks 0.1–0.3
answer the spec's three unverified points; Task 0.4 answers the points this plan adds. Each is
**VERIFIED offline** (source or a local run) **and UNVERIFIED live**: its live half runs on gcp-0,
after GCP parity Task 8.6 (GCP parity cross-plan edit, 2026-09-29; was "the next aws-0 rebuild")
(Tasks 3.1–3.4).

### Task 0.1: The SDK's content capture and the harness env (spec: unverified point 1)

**Question.** Can the SDK's Laminar instrumentation turn off content capture? Which instrument gives
token counts and `traceparent`?

**Pinned from source** (`openhands-sdk` 1.49.6 `openhands/sdk/observability/laminar.py`; `lmnr` 0.7.60).

Enabling and exporting:
- Observability switches on when any of `LMNR_PROJECT_API_KEY`, `OTEL_ENDPOINT`,
  `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` or `OTEL_EXPORTER_OTLP_ENDPOINT` is set.
- `maybe_init_laminar()` runs at import of `openhands.sdk.agent.agent`, in agent-server and in `agent-run`.
- lmnr reads `OTEL_EXPORTER_OTLP_TRACES_{ENDPOINT,PROTOCOL,HEADERS}` first, then
  `OTEL_EXPORTER_OTLP_*`, then `OTEL_*` (`sdk/utils.py get_otel_env_var`).
- `http/protobuf` selects the HTTP exporter (gzip). A URL that already has a path is used as is.
- `LMNR_INSTRUMENTS` is a comma list of `lmnr.Instruments` values.

Content:
- `enable_content_tracing = True` is hardcoded (`opentelemetry_lib/__init__.py`).
- `LMNR_TRACE_CONTENT` gates only the openai, anthropic, groq and google instrumentations.
- The LiteLLM wrapper sets `gen_ai.input.messages`, `gen_ai.output.messages` and `gen_ai.tool.definitions`
  with no gate.
- `@observe` records `lmnr.span.input` and `lmnr.span.output`.

The resource is built as `Resource(attributes=…)`, so `OTEL_RESOURCE_ATTRIBUTES` and `OTEL_SERVICE_NAME`
are ignored: `service.name` is `argv[0]`.

A trap: lmnr's log exporter reads the same `ENDPOINT` key, so with a traces URL any OTel log record
would be POSTed to `/v1/traces`. The base URL avoids it (O19): lmnr appends `/v1/traces` or
`/v1/logs`, and the run CNP drops the second.

**Run 2026-09-27** (harness `ghcr.io/smana/agent-harness:v0.1.0-pr2110.29b5f228`, fake OpenAI
server, local collector with a `debug` exporter):

| `LMNR_INSTRUMENTS` | Spans | Trace ids | Tokens on a span | `traceparent` on the model request | Content attributes |
|---|---|---|---|---|---|
| `openai` | `conversation`, `conversation.send_message`, `conversation.run`, `agent.step`, `llm.openai/agent-default`, `openai.chat`, `FinishAction` | 1 | `gen_ai.usage.input_tokens`/`output_tokens` on `openai.chat`; `gen_ai.usage.cost` on `llm.*` | **yes** | `lmnr.span.input`, `lmnr.span.output`, `llm.headers` |
| `litellm` | the same, `litellm.completion` instead of `openai.chat` | 1 | yes | **no** | the above plus `gen_ai.input.messages`, `gen_ai.output.messages`, `gen_ai.tool.definitions` |
| `openai`, with the base `OTEL_EXPORTER_OTLP_ENDPOINT` (O19) | the same 7 as the first row | 1 | yes | **yes** | as the first row |

**Outcome: VERIFIED offline, negative.** Content capture cannot be turned off, so the spec's
fallback holds: the collector's allowlist is the control (O2). Hygiene is `LMNR_INSTRUMENTS=openai` and
`LMNR_TRACE_CONTENT=false` (O6). `openai` is pinned because it alone carries `traceparent`, which
joins agent-router's spans to the trace.

**UNVERIFIED live** (Task 3.3):
- agent-server's SIGTERM path exports the root `conversation` span, and the run is one trace;
- `traceparent` survives identity-proxy.

**Fallback.** If the root span is lost, O13 applies. If the run spans several traces, the run page
lists every trace with the run's `agent.run_id` (its search is by tag, not by trace id), and Δ8 is
proposed then: "one trace per conversation step".

- [ ] **Step 1: Re-run the spike on the harness CC-O1 pins** (only if the pin moved since
  `v0.1.0-pr2110.29b5f228`)

Set `S` to the session scratchpad and `IMG` to the image in CC-O1's `_HARNESS_PROFILES.openhands.image`
(tag and digest). Write `$S/spike-collector.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  telemetry:
    metrics:
      level: none
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
```

and `$S/spike-sdk-traces.py`:

```python
"""Observability plan Task 0.1: what the SDK's Laminar tracing sends, and whether
traceparent reaches the model endpoint. Runs inside the harness image against a fake
OpenAI-compatible server; spans go to a local collector's debug exporter."""
import http.server
import json
import os
import threading

SEEN = []


class Fake(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        SEEN.append({"path": self.path, "traceparent": self.headers.get("traceparent")})
        call = {"id": "call_1", "type": "function",
                "function": {"name": "finish", "arguments": json.dumps({"message": "COMPLETION-MARKER-Q4"})}}
        reply = {"id": "chatcmpl-spike", "object": "chat.completion", "created": 0, "model": "agent-default",
                 "choices": [{"index": 0, "finish_reason": "tool_calls",
                              "message": {"role": "assistant", "content": None, "tool_calls": [call]}}],
                 "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}}
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 9999), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()

from openhands.sdk import LLM, Conversation  # noqa: E402  (env must be set before import)
from openhands.tools.preset.default import get_default_agent  # noqa: E402

llm = LLM(model="openai/agent-default", base_url="http://127.0.0.1:9999/v1", api_key="spike",  # pragma: allowlist secret
          usage_id="agent", num_retries=0, input_cost_per_token=1.4e-6, output_cost_per_token=4.4e-6)
agent = get_default_agent(llm=llm, cli_mode=True)
os.makedirs("/tmp/spike-ws", exist_ok=True)
conv = Conversation(agent=agent, workspace="/tmp/spike-ws")
conv.send_message("PROMPT-MARKER-Q4: call finish.")
conv.run()
conv.close()
try:
    from lmnr import Laminar
    Laminar.flush()
except Exception as exc:  # noqa: BLE001
    print("flush:", exc)
print("MODEL-REQUESTS", json.dumps(SEEN))
```

Run (one command per line; the collector is restarted between instruments):

```bash
docker network create obs-spike
docker run -d --rm --name obs-collector --network obs-spike -v "$S/spike-collector.yaml:/conf/c.yaml:ro" otel/opentelemetry-collector-k8s:0.160.0 --config=/conf/c.yaml
docker run --rm --network obs-spike -e OTEL_EXPORTER_OTLP_ENDPOINT=http://obs-collector:4318 -e OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf -e LMNR_INSTRUMENTS=openai -e LMNR_TRACE_CONTENT=false -e HOME=/tmp -v "$S/spike-sdk-traces.py:/spike.py:ro" --entrypoint /agent-server/.venv/bin/python "$IMG" /spike.py | tail -1
docker logs obs-collector 2>&1 | grep -oE '^\s+-> [A-Za-z0-9_.]+' | sed 's/.*-> //' | sort -u
docker stop obs-collector && docker network rm obs-spike
```

Expected: `MODEL-REQUESTS [{"path": "/v1/chat/completions", "traceparent": "00-…-01"}]`; the key list
of the table's `openai` row. A key that is neither content nor already allowlisted gets a decision in
O-1's PR body: add it to `allowed_keys` (Task 2.2) or leave it out.

### Task 0.2: Envoy Gateway 1.9 OTLP export (spec: unverified point 2)

**Pinned from source and schema** (EG `v1.9.1`, the version `flux/sources/ocirepo-envoy-gateway.yaml` pins):
- `internal/gatewayapi/listener.go` `processTracing` sets `d.Protocol = ir.GRPC` for every
  OpenTelemetry destination ("TODO: update when OTLP/HTTP is completely supported").
- The `EnvoyProxy` schema has no protocol field, and describes `provider.openTelemetry.headers` as
  "gRPC initial metadata".
- The keys used here are: `spec.telemetry.tracing.samplingRate`;
  `.provider.{type: OpenTelemetry, serviceName, backendRefs[{name, namespace, port}]}`; and `.tags`,
  a map of Envoy command operators.
- `processBackendRefsForTelemetry` checks no ReferenceGrant, so a cross-namespace `backendRefs` to
  `observability` needs none.

**Outcome: VERIFIED offline.** EG exports OTLP/**gRPC** only. VictoriaTraces takes OTLP/HTTP, but
the collector's `otlp/router` gRPC receiver takes EG's spans (O5), so the spec's fallback ("gateway
spans skipped") is not needed.

**UNVERIFIED live** (Task 3.1): the Envoy config dump carries `envoy.tracers.opentelemetry`, and
`agent-router` spans reach VictoriaTraces.

**Fallback.** If none arrive, remove the `tracing` block. The harness's `llm.*` spans still time
each model call, and the run page's router panel stays empty.

- [ ] **Step 1: The pin still holds on the day**

```bash
gh api 'repos/envoyproxy/gateway/contents/internal/gatewayapi/listener.go?ref=v1.9.1' -H 'Accept: application/vnd.github.raw' | grep -n -A2 'TODO: update when OTLP/HTTP'
```

Expected: the TODO, followed by `d.Protocol = ir.GRPC`. If the EG pin moved, re-run against the new tag.

### Task 0.3: kube-state-metrics custom-resource state (spec: unverified point 3)

**Pinned from source:**

- The chart `victoria-metrics-k8s-stack` 0.93.0 depends on `kube-state-metrics` `7.5.*`; 7.5.3,
  appVersion 2.19.1, is bundled.
- Its values expose `customResourceState.{enabled, create, name, key, config}` and `rbac.extraRules`.
- When `customResourceState` is enabled, the chart adds `list`/`watch` on
  `customresourcedefinitions` and mounts the config at
  `--custom-resource-state-config-file=/etc/customresourcestate/config.yaml`.
- KSM v2.19.1 `pkg/customresourcestate` takes `metricNamePrefix`, `labelsFromPath`, the `Info`,
  `StateSet` (`labelName`, `path`, `list`) and `Gauge` (`path`, `nilIsZero`) types, and parses RFC3339
  strings to epoch seconds.
- KSM watches installed CRDs, so a CRD that appears later is discovered.

**Outcome: VERIFIED offline** (`helm template` 2026-09-27 rendered the ConfigMap, the flag and both
RBAC rules).

**UNVERIFIED live** (Task 3.1): `agentrun_status_phase` series exist for a live run.

**Fallback** (the spec's). The run page's phase panel reads `kube_pod_status_phase{namespace="agents",
pod="xplane-run-<runId>"}`, and the end reason comes from the step log's `agent-run: conversation
ended with execution_status=`.

- [ ] **Step 1: Render on the day**

Write the Task 2.5 `kube-state-metrics:` block to `$S/ksm-values.yaml` (top-level key, without the
ConfigMap's indentation), then:

```bash
helm template vmks victoria-metrics-k8s-stack --repo https://victoriametrics.github.io/helm-charts/ --version 0.93.0 -n observability -f "$S/ksm-values.yaml" --show-only charts/kube-state-metrics/templates/deployment.yaml --show-only charts/kube-state-metrics/templates/role.yaml --show-only charts/kube-state-metrics/templates/crs-configmap.yaml | grep -E 'custom-resource-state-config-file|customresourcedefinitions|agentruns|kind: ConfigMap'
```

Expected: four lines, in that order.

### Task 0.4: The collector's filter and its run-id association (added by this plan)

**Pinned from source** (collector-contrib `v0.160.0`):
- `redaction` applies `allowed_keys` to resource, scope, span and span-event attributes, with
  `allow_all_keys: false` failing closed;
- `k8s_attributes` never overwrites a present resource attribute;
- with `filter.namespace` set and no namespace or node metadata extracted, `k8s_attributes` watches
  pods in that namespace only (`newNamespaceInformer` is a no-op), so a `Role` in `agents` suffices;
- `filter` takes `trace_conditions`;
- `transform` takes grouped `trace_statements` with `resource.`, `span.` and `spanevent.` paths, plus
  `Substring`, `Len` and `truncate_all`.

**Run 2026-09-27.** `otelcol-k8s validate` on the rendered Task 2.2 config → exit 0. The Task 2.3
fixture through the same pipeline, with `k8s_attributes` stubbed, gave:
- three content attributes and the event's `exception.message` redacted (`redaction.redacted.count: 3`, then `1`);
- the spoofed `agent.run_id` replaced on the resource and the span;
- the unattributed span dropped;
- the status message capped at 128;
- `service.name` rewritten to `agent-harness`;
- `POST /v1/logs` → 404.

**Outcome: VERIFIED offline.**

**UNVERIFIED live** (Task 3.1): through the run CNP's L7 HTTP rule, the collector sees the run
pod's own IP, so `connection` association resolves `agent.run_id`.

**Fallback.**
- CC-O1 drops `rules.http` and keeps the L4 rule to :4318.
- The path restriction then rests on the collector, which serves only `/v1/traces` (logs and metrics
  paths 404).
- SO-4 proves "another port is `DROPPED`" plus the 404.
- Δ1 is re-worded to match.

- [ ] **Step 1: Nothing to run before Task 2.3**, which turns this run into a committed suite.

### Task 0.5: agent-server under a trigger trace, and at shutdown (further review, 2026-09-29)

**Question.** Does lmnr's `LMNR_SPAN_CONTEXT` (a JSON `LaminarSpanContext`: UUID-shaped
`trace_id` and `span_id`, `is_remote`, read at `Laminar.initialize` by
`_initialize_context_from_env`, lmnr 0.7.60) parent agent-server's root span on a given W3C
context? Is that root span exported when agent-run stops agent-server?

**Run 2026-09-29.** Harness `v0.1.0-pr2110.29b5f228`. agent-server was started and stopped as
`agent-run` does: SIGTERM, then `wait(10)`. The same fake model and debug collector as Task 0.1.
`LMNR_SPAN_CONTEXT` was built from `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`:

| Variant | Spans exported | Trace id | Root `conversation` |
|---|---|---|---|
| SIGTERM right after `finished` (5 s default batch) | **0** | — | lost |
| `OTEL_BSP_SCHEDULE_DELAY=500`, 4 s wait, SIGTERM | 6: `conversation.send_message`, `conversation.arun`, `agent.astep`, `llm.openai/agent-default`, `openai.chat`, `FinishAction` | `4bf92f…` | **lost**: the children's parent `638f…` never arrives |
| the same, plus `DELETE /api/conversations/<id>` before the wait | 7 | `4bf92f…` | exported, **Parent ID `00f067aa0ba902b7`** |

Every run also sent `traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-…-01` on the model request, so
agent-router's spans join the same trace.

**Outcome: VERIFIED offline.**
- `LMNR_SPAN_CONTEXT` makes the given context the parent of agent-server's root span.
- agent-server exports nothing at exit.
- Its root span ends only when the conversation closes.

This is the design of O21 and Task 2.8a.

**UNVERIFIED live** (Task 3.3a):
- the same under gVisor;
- the same through the run CNP, with the collector attributing the `agent-run` span by connection.

**Fallback.** If the root span still goes missing live, raise `FLUSH_WAIT_S` (Task 2.8a) up to the
25 s the pod's grace period leaves, and record it.

- [ ] **Step 1: Re-run on the day** only if the harness base image moved from agent-server
  `1.49.6`. The script is Task 0.1's harness with this `main` (write it to `$S/spike-server-traces.py`):

```python
import http.server, json, os, subprocess, threading, time, urllib.request

TRACE, PARENT = "4bf92f3577b34da6a3ce929d0e0e4736", "00f067aa0ba902b7"  # pragma: allowlist secret


class Fake(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        call = {"id": "c1", "type": "function", "function": {"name": "finish", "arguments": json.dumps({"message": "done"})}}
        data = json.dumps({"id": "c", "object": "chat.completion", "created": 0, "model": "agent-default",
                           "choices": [{"index": 0, "finish_reason": "tool_calls",
                                        "message": {"role": "assistant", "content": None, "tool_calls": [call]}}],
                           "usage": {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


threading.Thread(target=http.server.ThreadingHTTPServer(("127.0.0.1", 9999), Fake).serve_forever, daemon=True).start()
env = dict(os.environ, OH_SECRET_KEY="spike-secret-key-spike-secret-key", LMNR_SPAN_CONTEXT=json.dumps({  # pragma: allowlist secret
    "trace_id": "%s-%s-%s-%s-%s" % (TRACE[:8], TRACE[8:12], TRACE[12:16], TRACE[16:20], TRACE[20:]),
    "span_id": "00000000-0000-0000-%s-%s" % (PARENT[:4], PARENT[4:]), "is_remote": True}))
server = subprocess.Popen(["/agent-server/.venv/bin/python", "-m", "openhands.agent_server", "--host", "127.0.0.1", "--port", "8000"], cwd="/", env=env)
for _ in range(120):
    try:
        urllib.request.urlopen("http://127.0.0.1:8000/ready", timeout=2)
        break
    except Exception:  # noqa: BLE001
        time.sleep(1)
from openhands.sdk import LLM  # noqa: E402
from openhands.sdk.conversation.request import StartConversationRequest  # noqa: E402
from openhands.tools.preset.default import get_default_agent  # noqa: E402

plain = {"expose_secrets": True}
llm = LLM(model="openai/agent-default", base_url="http://127.0.0.1:9999/v1", api_key="spike", usage_id="agent", num_retries=0)
os.makedirs("/tmp/ws", exist_ok=True)
req = StartConversationRequest.model_validate({"workspace": {"working_dir": "/tmp/ws"}, "autotitle": False, "max_iterations": 5,
    "agent": get_default_agent(llm=llm, cli_mode=True).model_dump(mode="json", context=plain),
    "initial_message": {"role": "user", "content": [{"type": "text", "text": "call finish"}], "run": True}})
body = json.dumps(json.loads(req.model_dump_json(exclude_none=True, context=plain))).encode()
cid = json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000/api/conversations", data=body,
    method="POST", headers={"Content-Type": "application/json"}), timeout=30).read())["id"]
for _ in range(60):
    if json.loads(urllib.request.urlopen("http://127.0.0.1:8000/api/conversations/" + cid, timeout=10).read()).get("execution_status") == "finished":
        break
    time.sleep(1)
urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000/api/conversations/" + cid, method="DELETE"), timeout=30)
time.sleep(2)
server.terminate()
server.wait(10)
```

Run it as in Task 0.1 Step 1, with `-e OTEL_BSP_SCHEDULE_DELAY=1000 -e OH_ENABLE_VSCODE=false` added,
then:
`docker logs obs-collector 2>&1 | grep -E '^\s+(Trace ID|Parent ID|Name)\s+:' | paste - - - | grep 'Name.*: conversation$'`
Expected: one line with `Trace ID : 4bf92f3577b34da6a3ce929d0e0e4736` and `Parent ID : 00f067aa0ba902b7`.

---

## Phase 1 — CC-O1 in crossplane-configuration

Gate: `task check` exit 0, and the CI pre-release published with its `xrd-crds` artifact (inherited
from CC-H1).

### Task 1.1: CC-O1 — worktree

- [ ] **Step 1: Branch from CC-H1**

```bash
git -C ~/Sources/crossplane-configuration fetch origin
git -C ~/Sources/crossplane-configuration worktree add ~/Sources/crossplane-configuration-wt/agentrun-observability -b feat/agentrun-observability origin/ci/prerelease-xrd-crds
cd ~/Sources/crossplane-configuration-wt/agentrun-observability
```

Expected: the worktree at CC-H1's tip. If `origin/ci/prerelease-xrd-crds` does not exist, stop: SP2's
Task 0.5.2 comes first (O12).

### Task 1.2: The run's spans go to the collector's traces path only

**Files:**
- Modify: `apis/agentrun/kcl/main.k` (constants after `_BROKER_FQDN`; `_dnsNames`; the CNP egress list)
- Test: `apis/agentrun/kcl/main_test.k`

**Interfaces:**
- Produces: the run CNP egress rule `{toEndpoints: [{matchLabels: {io.kubernetes.pod.namespace: observability, app.kubernetes.io/name: agent-traces-collector}}], toPorts: [{ports: [{port: "4318", protocol: TCP}], rules: {http: [{method: POST, path: /v1/traces}]}}]}`, and `agent-traces-collector.observability.svc.cluster.local` in the DNS allowlist. O-1's collector carries that pod label and namespace (Task 2.2).

- [ ] **Step 1: Write the failing test**

Append to `main_test.k`:

```kcl
# Observability plan O1, SO-4: the run's spans go to the collector's OTLP/HTTP traces
# path and nowhere else. Not its gRPC port, not VictoriaTraces: the collector is what
# strips content before anything is stored.
test_traces_go_only_to_the_collector_traces_path = lambda {
    _spec = _kind(_run({}), "CiliumNetworkPolicy")[0].spec
    _obs = [e for e in _spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "observability"]
    assert len(_obs) == 1, "one egress rule into observability"
    assert _obs[0].toEndpoints == [{matchLabels = {"io.kubernetes.pod.namespace" = "observability", "app.kubernetes.io/name" = "agent-traces-collector"}}]
    assert _obs[0].toPorts == [{ports = [{port = "4318", protocol = "TCP"}], rules = {http = [{method = "POST", path = "/v1/traces"}]}}]
    assert "agent-traces-collector.observability.svc.cluster.local" in [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: FAIL on `test_traces_go_only_to_the_collector_traces_path` with `one egress rule into observability`.

- [ ] **Step 3: Implement**

In `main.k`, after `_BROKER_FQDN`:

```kcl
# The agent trace collector (cloud-native-ref observability plan, O1): the only place a
# run's spans may go. It drops every non-metadata attribute before VictoriaTraces.
_TRACES_FQDN = "agent-traces-collector.observability.svc.cluster.local"
_TRACES_PORT = 4318
```

`_dnsNames` becomes:

```kcl
    _dnsNames = [_ROUTER_FQDN, _TRACES_FQDN] + ([_BROKER_FQDN] if _roomRef else []) + _fqdns
```

In `_networkPolicy`'s `egress`, after the agent-router rule and before the `toFQDNs` rule:

```kcl
                {
                    # Spans to the collector's OTLP/HTTP traces path only (SO-4): neither its
                    # gRPC port nor VictoriaTraces, which would skip the content filter.
                    toEndpoints = [{
                        matchLabels = {"io.kubernetes.pod.namespace" = "observability", "app.kubernetes.io/name" = "agent-traces-collector"}
                    }]
                    toPorts = [{
                        ports = [{port = str(_TRACES_PORT), protocol = "TCP"}]
                        rules.http = [{method = "POST", path = "/v1/traces"}]
                    }]
                }
```

- [ ] **Step 3b: Fix the file header's CNP line**

The header's `CiliumNetworkPolicy` line becomes `default-deny, class-scoped gateway port, trace
collector, FQDN profiles`.

- [ ] **Step 4: Run the suite**

Run: `cd apis/agentrun/kcl && kcl fmt . && kcl test . -Y settings-example.yaml`
Expected: every test passes, the existing CNP tests included. `egress[0]` is still the DNS rule, and
no rule uses `toEntities`.

- [ ] **Step 5: Commit**

```bash
git add apis/agentrun/kcl/main.k apis/agentrun/kcl/main_test.k
git commit -m "feat(agentrun): let a run send spans to the trace collector's traces path"
```

### Task 1.3: The harness exports traces, metadata-minded

**Files:**
- Modify: `apis/agentrun/kcl/main.k` (the harness `env` list)
- Test: `apis/agentrun/kcl/main_test.k`

**Interfaces:**
- Consumes: `_TRACES_FQDN`, `_TRACES_PORT` (Task 1.2).
- Produces: the harness env `OTEL_EXPORTER_OTLP_ENDPOINT` (base URL), `OTEL_EXPORTER_OTLP_PROTOCOL`,
  `LMNR_INSTRUMENTS=openai`, `LMNR_TRACE_CONTENT=false`. agent-server inherits them.

- [ ] **Step 1: Write the failing test**

```kcl
# Observability plan O6, O19 (Task 0.1). A base URL, so lmnr appends /v1/traces for spans
# and /v1/logs for anything else, which the run CNP drops. `openai` is the one instrument
# that injects traceparent and honours LMNR_TRACE_CONTENT. The collector, not this env,
# keeps content out of VictoriaTraces.
test_harness_exports_traces_to_the_collector = lambda {
    _env = {e.name: e.value for e in _pod(_run({})).containers[0].env}
    assert _env.OTEL_EXPORTER_OTLP_ENDPOINT == "http://agent-traces-collector.observability.svc.cluster.local:4318"
    assert _env.OTEL_EXPORTER_OTLP_PROTOCOL == "http/protobuf"
    assert _env.LMNR_INSTRUMENTS == "openai"
    assert _env.LMNR_TRACE_CONTENT == "false"
    assert "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT" not in _env, "a traces URL would also carry lmnr's log records (O19)"
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: FAIL on `test_harness_exports_traces_to_the_collector` (no `OTEL_EXPORTER_OTLP_ENDPOINT` key).

- [ ] **Step 3: Implement**

Append to the harness container's `env`, after `HOME`:

```kcl
                            # Spans to the trace collector (observability plan O19): a base URL, so lmnr
                            # 0.7.60 posts spans to /v1/traces and any log record to /v1/logs, which the
                            # run CNP drops. http/protobuf: the CNP rule is an L7 HTTP one.
                            {name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://{}:{}".format(_TRACES_FQDN, _TRACES_PORT)}
                            {name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf"}
                            # Hygiene only (O6): the collector drops content. The OpenAI instrument
                            # honours LMNR_TRACE_CONTENT and injects traceparent; lmnr's LiteLLM one does neither.
                            {name = "LMNR_INSTRUMENTS", value = "openai"}
                            {name = "LMNR_TRACE_CONTENT", value = "false"}
```

- [ ] **Step 4: Run the suite**

Run: `cd apis/agentrun/kcl && kcl fmt . && kcl test . -Y settings-example.yaml`
Expected: every test passes.

- [ ] **Step 5: Commit**

```bash
git add apis/agentrun/kcl/main.k apis/agentrun/kcl/main_test.k
git commit -m "feat(agentrun): export harness traces to the collector"
```

### Task 1.3a: The factory's traceparent reaches the harness (further review, 2026-09-29; O21)

**Files:**
- Modify: `apis/agentrun/kcl/main.k` (a `_traceparent` helper before `_pullRequest`; `_tp` after `_pr`; the harness `env` list)
- Test: `apis/agentrun/kcl/main_test.k`

**Interfaces:**
- Consumes: the claim annotation `agents.ogenki.io/traceparent`, which SP3's `runs.Build` writes at
  creation (SP3 Task 1.5a). The value is W3C `00-<32 hex>-<16 hex>-<2 hex>`.
- Produces: harness env `TRACEPARENT`, only for a valid value. Task 2.8a's `start_run_span` reads it.

- [ ] **Step 1: Write the failing test**

```kcl
# Observability plan O21 (SP3 R46): the factory's task span reaches the harness as TRACEPARENT,
# only when the annotation is a W3C traceparent. None, or a malformed one: a fresh trace.
test_traceparent_annotation_reaches_the_harness = lambda {
    _tp = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
    _envOf = lambda annotations: any -> any {
        {e.name: e.value for e in _pod(_render(_xr({}, annotations, {}, {}), {}, _DXR)).containers[0].env}
    }
    assert _envOf({"agents.ogenki.io/traceparent" = _tp}).TRACEPARENT == _tp
    assert "TRACEPARENT" not in _envOf({"agents.ogenki.io/traceparent" = "00-4bf9-00f0-01"}), "a malformed traceparent is never projected"
    assert "TRACEPARENT" not in _envOf({}), "no annotation: the harness starts a fresh trace (task agent:run)"
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd apis/agentrun/kcl && kcl test . -Y settings-example.yaml`
Expected: `test_traceparent_annotation_reaches_the_harness: FAIL`, `PASS: 46/47`.

- [ ] **Step 3: Implement**

Before `_pullRequest`:

```kcl
# SP3's factory writes its task span's W3C traceparent at creation (R46). Correlation only
# (observability plan O22): a malformed value is never projected.
_traceparent = lambda annotations: any -> any {
    _v = _get(annotations, "agents.ogenki.io/traceparent")
    _v if _v and regex.match(_v, "^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$") else None
}
```

After `_pr = _pullRequest(_ann, _repo, _previous?.pullRequest)`: `_tp = _traceparent(_ann)`. The harness
`env` list's closing bracket, after `LMNR_TRACE_CONTENT`, becomes (no mutation, constitution 2.1):

```kcl
                        ] + ([{name = "TRACEPARENT", value = _tp}] if _tp else [])
```

- [ ] **Step 4: Run the suite**

Run: `cd apis/agentrun/kcl && kcl fmt . && kcl test . -Y settings-example.yaml`
Expected: `PASS: 47/47`. Verified on the scratch copy, 2026-09-29. The examples carry no annotation,
so the goldens do not change.

- [ ] **Step 5: Commit**

```bash
git add apis/agentrun/kcl/main.k apis/agentrun/kcl/main_test.k
git commit -m "feat(agentrun): hand the factory's traceparent to the harness"
```

### Task 1.4: `kubectl get agentrun` shows PRINCIPAL, PR, TOKENS and REASON (O8)

**Files:**
- Modify: `apis/agentrun/definition.yaml` (`additionalPrinterColumns`)

- [ ] **Step 1: The check that fails today**

Run: `python3 -c "import yaml; d=yaml.safe_load(open('apis/agentrun/definition.yaml')); print([c['name'] for c in d['spec']['versions'][0]['additionalPrinterColumns']])"`
Expected: `['Role', 'Class', 'Phase', 'Branch']`.

- [ ] **Step 2: Add the columns** after `Branch`:

```yaml
        # Observability plan O8 (formerly SP3 CC-F1, SD13). TOKENS and PR stay empty until a
        # meter (SP4 PR 2) and the factory (SP3) write their annotations.
        - name: Principal
          type: string
          jsonPath: .spec.principal
        - name: PR
          type: string
          jsonPath: .status.pullRequest
        - name: Tokens
          type: integer
          jsonPath: .status.usage.tokens
        - name: Reason
          type: string
          jsonPath: .status.reason
```

- [ ] **Step 3: Re-run the check, and the schema gate**

Run: the Step 1 command, then `task schema`
Expected: `['Role', 'Class', 'Phase', 'Branch', 'Principal', 'PR', 'Tokens', 'Reason']`; `task schema` exit 0.

- [ ] **Step 4: Commit**

```bash
git add apis/agentrun/definition.yaml
git commit -m "feat(agentrun): principal, PR, tokens and reason printer columns"
```

### Task 1.5: Goldens, README, gate and CC-O1's pre-release

**Files:**
- Modify: `tests/golden/agentrun-basic.yaml`, `tests/golden/agentrun-complete.yaml`, `apis/agentrun/kcl/README.md`

- [ ] **Step 1: The render gate names the drift**

Run: `task render`
Expected: `DIFFER agentrun-basic.yaml` and `DIFFER agentrun-complete.yaml`. The only hunks are the DNS
name, the new egress rule and the four env vars. Any other hunk is a bug: stop.

- [ ] **Step 2: Re-render the two goldens**

```bash
crossplane render examples/agentrun-basic.yaml apis/agentrun/composition.yaml functions.yaml --extra-resources examples/environmentconfig.yaml > tests/golden/agentrun-basic.yaml
crossplane render examples/agentrun-complete.yaml apis/agentrun/composition.yaml functions.yaml --extra-resources examples/environmentconfig.yaml > tests/golden/agentrun-complete.yaml
```

- [ ] **Step 3: README**

In `apis/agentrun/kcl/README.md`'s resource table, the CNP row's parenthesis becomes `(DNS L7
allowlist, the class's gateway port, octo-sts, the trace collector's POST /v1/traces, FQDN
profiles)`.

- [ ] **Step 4: Gate, commit, PR**

```bash
task check
git add tests/golden apis/agentrun/kcl/README.md
git commit -m "test(agentrun): re-render the goldens for the trace egress"
git push -u origin feat/agentrun-observability
gh pr create --repo Smana/crossplane-configuration --base ci/prerelease-xrd-crds --draft \
  --title "feat(agentrun): trace egress, harness OTEL env and printer columns" \
  --body "cloud-native-ref agent observability plan (CC-O1): the run CNP admits POST /v1/traces on the trace collector only (SO-4), the harness exports OTLP/HTTP spans, and kubectl get agentrun gains PRINCIPAL, PR, TOKENS and REASON (moved from SP3 CC-F1). Stacked on CC-H1; merge-only; nothing merges before the programme's UX sign-off."
gh pr checks --repo Smana/crossplane-configuration --watch
```

Expected: `task check` exit 0; CI green. The job summary names the package pre-release
`v0.7.2-pr<N>.<sha7>` and its `crossplane-configuration-xrd-crds` artifact. If `generate-sync`
fails, run `task generate` and commit what it wrote. Record the pre-release: Task 2.1 pins it.

---

## Phase 2 — O-1 in this repo

Gate: every gate exit 0, CI green with `Kubernetes validation ☸` (H-1's B2 step pulls CC-O1's XRD
artifact), and O-1 open as a draft on `fix/agent-review-hardening`.

### Task 2.1: O-1 — worktree, stack, pin

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/agent-observability`, then `git reset --hard
origin/fix/agent-review-hardening` before the first commit (the tool branches from `origin/main`;
this branch stacks). Merge `origin/main` in: the pre-push hook requires it.

- [ ] **Step 2: The base carries both umbrellas suspended**

Run: `grep -n '^  suspend:' clusters/aws-0/agent-platform.yaml clusters/aws-0/ai-gateway.yaml`
Expected: `suspend: true` twice. `false` belongs only to integration's test-only commit (review B1).

- [ ] **Step 3: Pin CC-O1's pre-release**

In `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml`, the package tag
becomes Task 1.5's pre-release. `apps/platform/app-wizard/app.yaml` stays on `v0.7.1`.

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && grep -c 'Principal' "$XRD_CRDS_FILE" && ./scripts/ci/validate-manifests.sh`
Expected: a positive count (the new columns are in the artifact), then `Invalid: 0, Skipped: 0`.

```bash
git add infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml
git commit -m "chore(crossplane): pin CC-O1's pre-release for the trace egress"
```

### Task 2.2: The collector (O1–O5, O18)

**Files:**
- Create: `scripts/ci/tests/test-agent-observability.py`
- Create: `flux/sources/helmrepo-open-telemetry.yaml`
- Create: `observability/base/agent-platform/agent-traces-collector.yaml`
- Modify: `observability/base/agent-platform/kustomization.yaml`

**Interfaces:**
- Consumes: CC-O1's egress rule, which selects `io.kubernetes.pod.namespace: observability`,
  `app.kubernetes.io/name: agent-traces-collector` on :4318.
- Produces:
  - Service `agent-traces-collector.observability`, ports `otlp` 4317, `otlp-http` 4318, `metrics` 8888;
  - pod labels `app.kubernetes.io/name: agent-traces-collector`, `app.kubernetes.io/instance: agent-traces`;
  - VictoriaTraces spans with `service.name=agent-harness` and `agent.run_id` on the resource and every span;
  - the suite's `check()` and `find()` helpers, which Tasks 2.4–2.7 extend.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-agent-observability.py`:

```python
#!/usr/bin/env python3
# requires: python3
"""Agent observability on the real tree (docs/superpowers/plans/2026-09-27-agent-observability-plan.md).
The trace collector keeps metadata only and takes no run id from a span, agent-router traces to
it, kube-state-metrics reads AgentRuns, and the two dashboards are wired to all of it."""
import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    print("SKIP: pyyaml not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
errors = []


def check(ok, message):
    if not ok:
        errors.append(message)


def find(rel, kind, name):
    for d in yaml.safe_load_all((ROOT / rel).read_text()):
        if d and d.get("kind") == kind and d["metadata"]["name"] == name:
            return d
    errors.append(f"{rel}: no {kind} {name}")
    return {}


COLLECTOR = "observability/base/agent-platform/agent-traces-collector.yaml"
# Keys that carry prompts, completions, tool input or output, headers or error text (lmnr
# 0.7.60, OpenHands SDK 1.49.6, OTel semconv). None may be allowlisted (rulings O2, O18).
CONTENT = re.compile(r"^(gen_ai\.(input|output|prompt|completion|tool\.definitions|system_instructions)"
                     r"|lmnr\.span\.(input|output)|llm\.headers|exception\.(message|stacktrace))")


def check_collector():
    raw = (ROOT / COLLECTOR).read_text()
    check(not re.search(r"(?<!\$)\$\{env:", raw), "every ${env:…} is escaped as $${env:…} for Flux")
    values = find(COLLECTOR, "HelmRelease", "agent-traces-collector").get("spec", {}).get("values", {})
    image = values.get("image", {})
    check(image.get("repository") == "otel/opentelemetry-collector-k8s" and image.get("digest", "").startswith("sha256:"),
          "the collector is otelcol-k8s, pinned by digest")
    check(not values.get("presets"), "no chart preset: k8s_attributes must run after the strip step (O3)")
    cfg = values.get("alternateConfig", {})
    pipes = cfg.get("service", {}).get("pipelines", {})
    check(set(pipes) == {"traces/agents", "traces/router"}, f"pipelines are traces/agents and traces/router, got {sorted(pipes)}")
    agents, router = pipes.get("traces/agents", {}), pipes.get("traces/router", {})
    check(agents.get("receivers") == ["otlp/agents"] and router.get("receivers") == ["otlp/router"], "one receiver per pipeline (O5)")
    receivers = cfg.get("receivers", {})
    check(list(receivers.get("otlp/agents", {}).get("protocols", {})) == ["http"], "sandboxes speak OTLP/HTTP only")
    check(list(receivers.get("otlp/router", {}).get("protocols", {})) == ["grpc"], "agent-router speaks OTLP/gRPC only (EG 1.9)")
    want = ["memory_limiter", "transform/untrusted", "k8s_attributes", "filter/unattributed",
            "transform/attribute", "redaction", "transform/cap", "batch"]
    check(agents.get("processors") == want, f"traces/agents processors are {want}, got {agents.get('processors')}")
    proc = cfg.get("processors", {})
    k8s = proc.get("k8s_attributes", {})
    check(k8s.get("pod_association") == [{"sources": [{"from": "connection"}]}],
          "the run id comes from the connection only, never a span's resource attributes (O4)")
    check(k8s.get("filter", {}).get("namespace") == "agents", "k8s_attributes watches pods in agents only (its Role)")
    labels = {l["tag_name"]: l["key"] for l in k8s.get("extract", {}).get("labels", [])}
    check(labels.get("agent.run_id") == "agents.ogenki.io/run-id", "agent.run_id is the pod's agents.ogenki.io/run-id label")
    strip = [s for g in proc.get("transform/untrusted", {}).get("trace_statements", []) for s in g.get("statements", [])]
    for target in ("resource", "span"):
        check(f'delete_key({target}.attributes, "agent.run_id")' in strip, f"the client's {target} agent.run_id is deleted first")
    check(proc.get("filter/unattributed", {}).get("trace_conditions") == ['resource.attributes["agent.run_id"] == nil'],
          "a span no run sent is dropped")
    redaction = proc.get("redaction", {})
    allowed = redaction.get("allowed_keys", [])
    check(redaction.get("allow_all_keys") is False, "redaction is an allowlist (O2)")
    check({"agent.run_id", "service.name", "gen_ai.usage.input_tokens", "gen_ai.request.model"} <= set(allowed),
          "the run id, service name, model and token counts are kept")
    leaks = [k for k in allowed if CONTENT.match(k)]
    check(not leaks, f"content keys allowlisted: {leaks}")
    endpoint = cfg.get("exporters", {}).get("otlp_http/victoriatraces", {}).get("traces_endpoint")
    check(endpoint == "http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces",
          f"the exporter writes VictoriaTraces' OTLP path, got {endpoint!r}")
    role = find(COLLECTOR, "Role", "agent-traces-collector")
    check(role.get("metadata", {}).get("namespace") == "agents"
          and role.get("rules") == [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list", "watch"]}],
          "the collector reads pods in agents and nothing else")
    cnp = find(COLLECTOR, "CiliumNetworkPolicy", "agent-traces-collector").get("spec", {})
    ingress = {p["port"]: rule for rule in cnp.get("ingress", []) for tp in rule.get("toPorts", []) for p in tp["ports"]}
    check(set(ingress) == {"4318", "4317", "8888", "13133"}, f"collector ingress ports, got {sorted(ingress)}")
    run_peer = (ingress.get("4318", {}).get("fromEndpoints") or [{}])[0]
    check(run_peer.get("matchLabels") == {"io.kubernetes.pod.namespace": "agents"}
          and run_peer.get("matchExpressions") == [{"key": "agents.ogenki.io/run-id", "operator": "Exists"}],
          "only run pods reach :4318")
    router_peer = (ingress.get("4317", {}).get("fromEndpoints") or [{}])[0].get("matchLabels", {})
    check(router_peer == {"io.kubernetes.pod.namespace": "envoy-gateway-system",
                          "gateway.envoyproxy.io/owning-gateway-name": "agent-router",
                          "gateway.envoyproxy.io/owning-gateway-namespace": "agent-system"},
          "only agent-router's data plane reaches :4317")


CHECKS = [check_collector]

for run in CHECKS:
    run()
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, with a `FileNotFoundError` for `agent-traces-collector.yaml`.

- [ ] **Step 3: The HelmRepository**

`flux/sources/helmrepo-open-telemetry.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: open-telemetry
  namespace: observability
spec:
  interval: 12h
  url: https://open-telemetry.github.io/opentelemetry-helm-charts
```

- [ ] **Step 4: The collector**

`observability/base/agent-platform/agent-traces-collector.yaml`:

```yaml
---
# The agents' trace gate (ADR-0051, observability plan O1-O5, O18). A run's spans reach
# VictoriaTraces only through here. The run id comes from the sending pod's label, never
# from the span, and an allowlist drops every attribute that is not metadata.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: agent-traces-collector
  namespace: observability
spec:
  releaseName: agent-traces
  chart:
    spec:
      chart: opentelemetry-collector
      version: "0.173.1"
      sourceRef:
        kind: HelmRepository
        name: open-telemetry
        namespace: observability
  interval: 30m
  timeout: 5m
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
  values:
    mode: deployment
    nameOverride: agent-traces-collector
    fullnameOverride: agent-traces-collector
    image:
      repository: otel/opentelemetry-collector-k8s
      # 0.160.0. With a digest set the chart ignores the tag.
      digest: sha256:76d7a04f2291da1d8b7ce259468d09f0f9f44f71f67a5737539f64ca82b5bdb1
    command:
      name: otelcol-k8s
    replicaCount: 1
    serviceAccount:
      create: true
      name: agent-traces-collector
    # Its only API read is pods in `agents`, granted by the Role below (O3).
    clusterRole:
      create: false
    podSecurityContext:
      runAsNonRoot: true
      runAsUser: 10001
      runAsGroup: 10001
      seccompProfile:
        type: RuntimeDefault
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
    ports:
      jaeger-compact:
        enabled: false
      jaeger-thrift:
        enabled: false
      jaeger-grpc:
        enabled: false
      zipkin:
        enabled: false
      metrics:
        enabled: true
    startupProbe:
      httpGet:
        port: 13133
        path: /
      periodSeconds: 5
      failureThreshold: 24
    # The whole config: no chart default (jaeger, zipkin, prometheus receivers) and no
    # preset, whose k8s_attributes would run first and trust k8s.pod.ip on the span.
    alternateConfig:
      extensions:
        health_check:
          endpoint: $${env:MY_POD_IP}:13133
      receivers:
        # Run pods, through their CNP's POST /v1/traces rule (SO-4).
        otlp/agents:
          protocols:
            http:
              endpoint: $${env:MY_POD_IP}:4318
        # agent-router: Envoy Gateway 1.9 exports OTLP/gRPC only.
        otlp/router:
          protocols:
            grpc:
              endpoint: $${env:MY_POD_IP}:4317
      processors:
        memory_limiter:
          check_interval: 5s
          limit_percentage: 80
          spike_limit_percentage: 25
        # k8s_attributes never overwrites a key a span already carries (O4).
        transform/untrusted:
          error_mode: ignore
          trace_statements:
            - statements:
                - delete_key(resource.attributes, "agent.run_id")
                - delete_key(resource.attributes, "agent.role")
                - delete_key(resource.attributes, "k8s.pod.name")
                - delete_key(resource.attributes, "k8s.namespace.name")
            - statements:
                - delete_key(span.attributes, "agent.run_id")
        # By source IP only: a run cannot claim another run's id.
        k8s_attributes:
          auth_type: serviceAccount
          passthrough: false
          wait_for_metadata: true
          filter:
            namespace: agents
          pod_association:
            - sources:
                - from: connection
          extract:
            metadata:
              - k8s.namespace.name
              - k8s.pod.name
            labels:
              - tag_name: agent.run_id
                key: agents.ogenki.io/run-id
                from: pod
              - tag_name: agent.role
                key: agents.ogenki.io/role
                from: pod
        filter/unattributed:
          error_mode: ignore
          trace_conditions:
            - resource.attributes["agent.run_id"] == nil
        transform/attribute:
          error_mode: ignore
          trace_statements:
            - statements:
                - set(resource.attributes["service.name"], "agent-harness")
            - statements:
                - set(span.attributes["agent.run_id"], resource.attributes["agent.run_id"])
        # Metadata only (owner, 2026-09-27). Fails closed: a key not listed here is
        # dropped from resources, scopes, spans and span events (O2, O18).
        redaction:
          allow_all_keys: false
          summary: info
          allowed_keys:
            - service.name
            - agent.run_id
            - agent.role
            - k8s.namespace.name
            - k8s.pod.name
            - telemetry.sdk.language
            - telemetry.sdk.name
            - telemetry.sdk.version
            - gen_ai.system
            - gen_ai.provider.name
            - gen_ai.operation.name
            - gen_ai.request.model
            - gen_ai.response.model
            - gen_ai.response.id
            - gen_ai.response.finish_reasons
            - gen_ai.usage.input_tokens
            - gen_ai.usage.output_tokens
            - gen_ai.usage.prompt_tokens
            - gen_ai.usage.completion_tokens
            - gen_ai.usage.cache_read_input_tokens
            - gen_ai.usage.cache_creation_input_tokens
            - gen_ai.usage.reasoning_tokens
            - gen_ai.usage.cost
            - gen_ai.usage.input_cost
            - gen_ai.usage.output_cost
            - llm.usage.total_tokens
            - llm.request.type
            - llm.is_streaming
            - lmnr.span.type
            - lmnr.span.path
            - lmnr.span.instrumentation_source
            - lmnr.association.properties.session_id
            - lmnr.association.properties.metadata.tool_call_id
            - error.type
            - exception.type
            - exception.escaped
        transform/cap:
          error_mode: ignore
          trace_statements:
            - statements:
                - truncate_all(resource.attributes, 256)
            - statements:
                - truncate_all(span.attributes, 256)
                - set(span.name, Substring(span.name, 0, 128)) where Len(span.name) > 128
                - set(span.status.message, Substring(span.status.message, 0, 128)) where Len(span.status.message) > 128
            - statements:
                - truncate_all(spanevent.attributes, 256)
        batch: {}
      exporters:
        otlp_http/victoriatraces:
          traces_endpoint: http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces
      service:
        extensions: [health_check]
        telemetry:
          metrics:
            readers:
              - pull:
                  exporter:
                    prometheus:
                      host: $${env:MY_POD_IP}
                      port: 8888
        pipelines:
          traces/agents:
            receivers: [otlp/agents]
            processors: [memory_limiter, transform/untrusted, k8s_attributes, filter/unattributed, transform/attribute, redaction, transform/cap, batch]
            exporters: [otlp_http/victoriatraces]
          # Every attribute here is set by agent-router's EnvoyProxy manifest, not by a run.
          traces/router:
            receivers: [otlp/router]
            processors: [memory_limiter, batch]
            exporters: [otlp_http/victoriatraces]
---
# k8s_attributes reads run pods' labels, in `agents` only: filter.namespace scopes its
# informer there, and it extracts no namespace or node metadata (v0.160.0).
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: agent-traces-collector
  namespace: agents
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: agent-traces-collector
  namespace: agents
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: agent-traces-collector
subjects:
  - kind: ServiceAccount
    name: agent-traces-collector
    namespace: observability
---
# Default deny both ways (constitution 3.1). Run pods send OTLP/HTTP, agent-router
# OTLP/gRPC; the collector reads pods from the API server and writes VictoriaTraces.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agent-traces-collector
  namespace: observability
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: agent-traces-collector
      app.kubernetes.io/instance: agent-traces
  ingress:
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: agents
          matchExpressions:
            - key: agents.ogenki.io/run-id
              operator: Exists
      toPorts:
        - ports:
            - port: "4318"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: envoy-gateway-system
            gateway.envoyproxy.io/owning-gateway-name: agent-router
            gateway.envoyproxy.io/owning-gateway-namespace: agent-system
      toPorts:
        - ports:
            - port: "4317"
              protocol: TCP
    - fromEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vmagent
      toPorts:
        - ports:
            - port: "8888"
              protocol: TCP
    # kubelet's probes of the health_check extension.
    - fromEntities:
        - host
      toPorts:
        - ports:
            - port: "13133"
              protocol: TCP
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: vt-single
      toPorts:
        - ports:
            - port: "10428"
              protocol: TCP
---
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMServiceScrape
metadata:
  name: agent-traces-collector
  namespace: observability
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: agent-traces-collector
      app.kubernetes.io/instance: agent-traces
  endpoints:
    - port: metrics
```

Add `- agent-traces-collector.yaml` to `observability/base/agent-platform/kustomization.yaml`'s
`resources`.

- [ ] **Step 5: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; `check-substitution.py` exit 0; `Invalid: 0, Skipped: 0`, with Polaris clean on the
`agent-traces-collector` Deployment.

- [ ] **Step 6: Commit**

```bash
git add scripts/ci/tests/test-agent-observability.py flux/sources/helmrepo-open-telemetry.yaml observability/base/agent-platform
git commit -m "feat(observability): the agent trace collector, metadata only"
```

### Task 2.2a: The factory's task spans reach the platform port (further review, 2026-09-29; O20)

**Files:**
- Modify: `observability/base/agent-platform/agent-traces-collector.yaml` (the CNP's :4317 rule, the `traces/router` comment)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Produces: `agent-traces-collector.observability.svc.cluster.local:4317` (OTLP/gRPC, plaintext
  in-cluster) admits pods labelled `app.kubernetes.io/name: agent-factory` in `agent-system`.
  SP3's Task 1.12a adds the matching egress. It is inert until SP3 ships.

- [ ] **Step 1: Write the failing test**

Add to the suite:

```python
def check_platform_port():
    cnp = find(COLLECTOR, "CiliumNetworkPolicy", "agent-traces-collector").get("spec", {})
    peers = [p.get("matchLabels", {}) for rule in cnp.get("ingress", []) for tp in rule.get("toPorts", [])
             if any(x["port"] == "4317" for x in tp["ports"]) for p in rule.get("fromEndpoints", [])]
    check({"io.kubernetes.pod.namespace": "agent-system", "app.kubernetes.io/name": "agent-factory"} in peers,
          "SP3's factory sends its task spans to :4317 (O20)")
    check(all(p.get("io.kubernetes.pod.namespace") != "agents" for p in peers), "no sandbox ever reaches :4317 (O5, O20)")
```

and append `check_platform_port` to `CHECKS`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, `SP3's factory sends its task spans to :4317 (O20)`.

- [ ] **Step 3: Implement**

In the collector CNP, the :4317 rule's `fromEndpoints` gains a second entry, after agent-router's:

```yaml
        # SP3's factory: one root span per task (O20, SP3 R46). Inert until SP3 ships.
        - matchLabels:
            io.kubernetes.pod.namespace: agent-system
            app.kubernetes.io/name: agent-factory
```

The comment above `traces/router` becomes `# Platform spans: agent-router (EnvoyProxy manifest) and
SP3's factory (task spans, ids and end reason only). No sandbox reaches this receiver.`

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/agent-platform/agent-traces-collector.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): admit the factory's task spans on the platform port"
```

### Task 2.3: The filter, run for real (SO-3's offline half)

**Files:**
- Create: `scripts/ci/tests/test-agent-traces-filter.sh`

**Interfaces:**
- Consumes: Task 2.2's HelmRelease `alternateConfig` and image digest. The suite reads them, so a
  later edit to the pipeline is tested as written.

- [ ] **Step 1: Write the suite**

`scripts/ci/tests/test-agent-traces-filter.sh`:

```bash
#!/usr/bin/env bash
# requires: docker python3 curl
#
# The agent trace collector's filter, run for real (observability plan O2, O4, O18; SO-3's
# offline half). The HelmRelease's own agents pipeline, with k8s_attributes swapped for a
# stub that stamps the run id a pod label would, and the exporter swapped for `debug`. A
# span carrying a prompt, a completion, tool input, headers, an exception message and a
# spoofed run id must come out with metadata only; a span that no run sent is dropped.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
python3 -c 'import yaml' 2>/dev/null || { echo "SKIP: pyyaml not installed"; exit 77; }
docker info >/dev/null 2>&1 || { echo "SKIP: no docker daemon"; exit 77; }

tmp="$(mktemp -d)"
name="agent-traces-filter-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1; rm -rf "$tmp"' EXIT

image="$(ROOT="$ROOT" OUT="$tmp/relay.yaml" python3 - <<'PY'
import os
import yaml

path = os.path.join(os.environ["ROOT"], "observability/base/agent-platform/agent-traces-collector.yaml")
hr = next(d for d in yaml.safe_load_all(open(path)) if d and d["kind"] == "HelmRelease")
values = hr["spec"]["values"]
# Flux turns $${...} into ${...} before the chart sees it.
c = yaml.safe_load(yaml.safe_dump(values["alternateConfig"]).replace("$${", "${"))
# No API server here: the stub stamps what k8s_attributes reads from a run pod's labels.
c["processors"]["transform/stub-k8s"] = {"error_mode": "ignore", "trace_statements": [{"statements": [
    'set(resource.attributes["agent.run_id"], "testrun1") where resource.attributes["test.pod"] == "run"',
    'set(resource.attributes["k8s.pod.name"], "xplane-run-testrun1") where resource.attributes["test.pod"] == "run"']}]}
del c["processors"]["k8s_attributes"]
procs = c["service"]["pipelines"]["traces/agents"]["processors"]
procs[procs.index("k8s_attributes")] = "transform/stub-k8s"
c["exporters"] = {"debug": {"verbosity": "detailed"}}
for pipeline in c["service"]["pipelines"].values():
    pipeline["exporters"] = ["debug"]
c["receivers"]["otlp/agents"]["protocols"]["http"]["endpoint"] = "0.0.0.0:4318"
c["receivers"]["otlp/router"]["protocols"]["grpc"]["endpoint"] = "0.0.0.0:4317"
c["extensions"]["health_check"]["endpoint"] = "0.0.0.0:13133"
c["service"]["telemetry"] = {"metrics": {"level": "none"}}
yaml.safe_dump(c, open(os.environ["OUT"], "w"), sort_keys=False)
print("%s@%s" % (values["image"]["repository"], values["image"]["digest"]))
PY
)" || { echo "cannot build the test config" >&2; exit 1; }

cat >"$tmp/spans.json" <<'EOF'
{"resourceSpans":[
 {"resource":{"attributes":[{"key":"test.pod","value":{"stringValue":"run"}},{"key":"agent.run_id","value":{"stringValue":"spoofed1"}},{"key":"service.name","value":{"stringValue":"/agent-server/.venv/bin/python"}}]},
  "scopeSpans":[{"scope":{"name":"lmnr"},"spans":[
   {"traceId":"11111111111111111111111111111111","spanId":"2222222222222222","name":"llm.openai/agent-default","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000",
    "attributes":[{"key":"gen_ai.input.messages","value":{"stringValue":"[{\"role\":\"user\",\"content\":\"PROMPT-MARKER-Z7\"}]"}},
                  {"key":"gen_ai.output.messages","value":{"stringValue":"COMPLETION-MARKER-Z7"}},
                  {"key":"lmnr.span.input","value":{"stringValue":"TOOL-INPUT-MARKER-Z7"}},
                  {"key":"lmnr.span.output","value":{"stringValue":"TOOL-OUTPUT-MARKER-Z7"}},
                  {"key":"llm.headers","value":{"stringValue":"{'X-Title': 'HEADER-MARKER-Z7'}"}},
                  {"key":"agent.run_id","value":{"stringValue":"spoofed1"}},
                  {"key":"gen_ai.usage.input_tokens","value":{"intValue":"11"}},
                  {"key":"gen_ai.request.model","value":{"stringValue":"agent-default"}}],
    "events":[{"timeUnixNano":"1700000000500000000","name":"exception","attributes":[{"key":"exception.type","value":{"stringValue":"ValueError"}},{"key":"exception.message","value":{"stringValue":"EVENT-MARKER-Z7"}}]}],
    "status":{"code":2,"message":"STATUS-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-TAIL"}}]}]},
 {"resource":{"attributes":[{"key":"test.pod","value":{"stringValue":"other"}}]},
  "scopeSpans":[{"spans":[{"traceId":"33333333333333333333333333333333","spanId":"4444444444444444","name":"UNATTRIBUTED-SPAN","kind":1,"startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000001000000000"}]}]}
]}
EOF

docker run -d --name "$name" -p 127.0.0.1::4318 -v "$tmp/relay.yaml:/conf/relay.yaml:ro" "$image" --config=/conf/relay.yaml >/dev/null \
  || { echo "cannot start $image" >&2; exit 1; }
port="$(docker port "$name" 4318/tcp | head -1 | sed 's/.*://')"
code=""
for _ in $(seq 1 30); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data @"$tmp/spans.json" "http://127.0.0.1:$port/v1/traces")"
  [ "$code" = 200 ] && break
  sleep 1
done
[ "$code" = 200 ] || fail "POST /v1/traces answered '$code'"
[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$port/v1/logs")" = 404 ] \
  || fail "the collector serves no logs path"
sleep 2
out="$(docker logs "$name" 2>&1)"

for m in PROMPT COMPLETION TOOL-INPUT TOOL-OUTPUT HEADER EVENT; do
  grep -q "$m-MARKER-Z7" <<<"$out" && fail "$m content reached the exporter"
done
grep -q 'spoofed1' <<<"$out" && fail "a span's own agent.run_id survived"
grep -q 'UNATTRIBUTED-SPAN' <<<"$out" && fail "a span that no run sent was exported"
grep -q -- '-TAIL' <<<"$out" && fail "the status message was not capped"
[ "$(grep -c 'agent.run_id: Str(testrun1)' <<<"$out")" -eq 2 ] || fail "the run id is on the resource and on the span"
for keep in 'service.name: Str(agent-harness)' 'gen_ai.usage.input_tokens: Int(11)' 'gen_ai.request.model: Str(agent-default)' 'exception.type: Str(ValueError)'; do
  grep -qF "$keep" <<<"$out" || fail "metadata dropped: $keep"
done

if [ "$fails" -ne 0 ]; then
  printf '%s\n' "$out" | tail -60 >&2
  exit 1
fi
echo PASS
```

`chmod +x scripts/ci/tests/test-agent-traces-filter.sh`.

- [ ] **Step 2: See it pass, then see it bite**

Run: `bash scripts/ci/tests/test-agent-traces-filter.sh`
Expected: `PASS`. Then add `- gen_ai.input.messages` to `allowed_keys` and run it again.
Expected: `exit 1`, `FAIL  PROMPT content reached the exporter`. Then `git checkout
observability/base/agent-platform/agent-traces-collector.yaml`.

- [ ] **Step 3: Through the runner, then commit**

Run: `bash scripts/ci/tests/run.sh 2>&1 | grep -E 'agent-(traces-filter|observability)'`
Expected: `PASS  test-agent-traces-filter` and `PASS  test-agent-observability`, or `SKIP … no docker
daemon` on a host without Docker, which is never a pass.

```bash
git add scripts/ci/tests/test-agent-traces-filter.sh
git commit -m "test(observability): run the trace collector's filter against a content fixture"
```

### Task 2.4: agent-router traces to the collector (O5, O14)

**Files:**
- Modify: `infrastructure/base/agent-router/envoyproxy.yaml` (`spec.telemetry`)
- Modify: `infrastructure/base/agent-router/network-policy-data-plane.yaml` (`egress`)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Produces: spans with `service.name=agent-router` and span attribute `agent.principal` =
  `system:serviceaccount:agents:xplane-run-<runId>`. They join the harness trace when its
  `traceparent` survives identity-proxy.

- [ ] **Step 1: Write the failing test**

Add to the suite, before `CHECKS`:

```python
ROUTER = "infrastructure/base/agent-router"


def check_router():
    spec = find(f"{ROUTER}/envoyproxy.yaml", "EnvoyProxy", "agent-router-proxy").get("spec", {})
    tracing = spec.get("telemetry", {}).get("tracing", {})
    provider = tracing.get("provider", {})
    check(provider.get("type") == "OpenTelemetry" and provider.get("serviceName") == "agent-router",
          "agent-router exports OpenTelemetry spans as service agent-router")
    check(provider.get("backendRefs") == [{"name": "agent-traces-collector", "namespace": "observability", "port": 4317}],
          "agent-router's spans go to the collector's gRPC port (EG 1.9 exports gRPC only)")
    check(tracing.get("tags", {}).get("agent.principal") == "%REQ(X-AR-AGENT)%", "every span names the run's verified principal")
    egress = find(f"{ROUTER}/network-policy-data-plane.yaml", "CiliumNetworkPolicy", "agent-router-data-plane").get("spec", {}).get("egress", [])
    check(any((r.get("toEndpoints") or [{}])[0].get("matchLabels", {}).get("app.kubernetes.io/name") == "agent-traces-collector"
              and r["toPorts"][0]["ports"] == [{"port": "4317", "protocol": "TCP"}] for r in egress),
          "the data plane may reach the collector's :4317")
```

and `CHECKS = [check_collector, check_router]`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, with the four `check_router` messages.

- [ ] **Step 3: Implement**

In `envoyproxy.yaml`, under `telemetry:` after `accessLog:`:

```yaml
    # Spans to the agent trace collector over OTLP/gRPC, the one protocol Envoy Gateway
    # 1.9 exports. Its pipeline has no content filter: every attribute here is set by this
    # file. A run's traceparent survives identity-proxy, so these join the run's trace.
    tracing:
      samplingRate: 100
      provider:
        type: OpenTelemetry
        serviceName: agent-router
        backendRefs:
          - name: agent-traces-collector
            namespace: observability
            port: 4317
      tags:
        agent.principal: "%REQ(X-AR-AGENT)%"
```

In `network-policy-data-plane.yaml`, append to `egress`:

```yaml
    # Spans to the agent trace collector (EnvoyProxy telemetry.tracing).
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: observability
            app.kubernetes.io/name: agent-traces-collector
      toPorts:
        - ports:
            - port: "4317"
              protocol: TCP
```

In the CNP's header comment, "SP4 PR 2 adds the Bedrock egress here" is followed by: "The agent
trace collector's :4317 is here too (observability plan)."

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; `Invalid: 0, Skipped: 0`, with `assert-ai-gateway.py` still passing both Gateways.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/base/agent-router scripts/ci/tests/test-agent-observability.py
git commit -m "feat(agent-router): trace every request to the agent trace collector"
```

### Task 2.5: kube-state-metrics reads AgentRuns (O7, O11)

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` (a `kube-state-metrics:` block after `kubeProxy:`, before `crds:`)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Produces: the `agentrun_*` series of Global Constraints, each carrying `namespace`, `name`,
  `run_id`:
  - `agentrun_info` adds `role`, `data_class`, `principal`, `repository`, `model`, `branch`;
  - `agentrun_status_phase` adds `phase`;
  - `agentrun_outcome_info` adds `reason` and `pull_request`.

- [ ] **Step 1: Write the failing test**

Add to the suite:

```python
VM_VALUES = "observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml"
# The AgentRun XRD's status.phase enum (crossplane-configuration apis/agentrun/definition.yaml).
PHASES = ["Pending", "Running", "Succeeded", "Failed", "BudgetExhausted", "Revoked"]


def check_ksm():
    cm = find(VM_VALUES, "ConfigMap", "vm-common-helm-values")
    ksm = yaml.safe_load(cm.get("data", {}).get("values.yaml", "{}")).get("kube-state-metrics", {})
    check(ksm.get("rbac", {}).get("extraRules") == [{"apiGroups": ["cloud.ogenki.io"], "resources": ["agentruns"], "verbs": ["list", "watch"]}],
          "KSM reads agentruns, list and watch only")
    crs = ksm.get("customResourceState", {})
    res = (crs.get("config", {}).get("spec", {}).get("resources") or [{}])[0]
    check(crs.get("enabled") is True and res.get("groupVersionKind") == {"group": "cloud.ogenki.io", "version": "v1alpha1", "kind": "AgentRun"},
          "custom-resource state covers AgentRun")
    check(res.get("metricNamePrefix") == "agentrun", "the series are agentrun_*")
    check(res.get("labelsFromPath", {}).get("run_id") == ["status", "runId"], "every agentrun_* series carries run_id")
    metrics = {m["name"]: m["each"] for m in res.get("metrics", [])}
    want = {"info", "status_phase", "outcome_info", "usage_tokens", "budget_max_tokens",
            "started_timestamp_seconds", "finished_timestamp_seconds"}
    check(set(metrics) == want, f"agentrun metrics are {sorted(want)}, got {sorted(metrics)}")
    check(metrics.get("status_phase", {}).get("stateSet", {}).get("list") == PHASES, "status_phase lists every XRD phase")
```

and `CHECKS = [check_collector, check_router, check_ksm]`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, starting with `KSM reads agentruns, list and watch only`.

- [ ] **Step 3: Implement**

In the ConfigMap's `values.yaml`, after the `kubeProxy:` block (four-space indentation, as its
siblings):

```yaml
    kube-state-metrics:
      # AgentRun state for the "Agent run" and "Agent fleet" dashboards (agent observability
      # plan, O11). The CRD ships in the always-on Crossplane package and KSM discovers it; with
      # no runs there are no series. status.usage and status.pullRequest stay empty until a
      # meter and the factory write their annotations (O7).
      rbac:
        extraRules:
          - apiGroups: ["cloud.ogenki.io"]
            resources: ["agentruns"]
            verbs: ["list", "watch"]
      customResourceState:
        enabled: true
        config:
          kind: CustomResourceStateMetrics
          spec:
            resources:
              - groupVersionKind:
                  group: cloud.ogenki.io
                  version: v1alpha1
                  kind: AgentRun
                metricNamePrefix: agentrun
                labelsFromPath:
                  namespace: [metadata, namespace]
                  name: [metadata, name]
                  run_id: [status, runId]
                metrics:
                  - name: info
                    help: "An AgentRun's fixed fields"
                    each:
                      type: Info
                      info:
                        labelsFromPath:
                          role: [spec, role]
                          data_class: [spec, dataClass]
                          principal: [spec, principal]
                          repository: [spec, repository]
                          model: [spec, model]
                          branch: [status, branch]
                  - name: status_phase
                    help: "The AgentRun's phase, one series per phase"
                    each:
                      type: StateSet
                      stateSet:
                        labelName: phase
                        path: [status, phase]
                        list: [Pending, Running, Succeeded, Failed, BudgetExhausted, Revoked]
                  - name: outcome_info
                    help: "Why the run ended, and its pull request, once known"
                    each:
                      type: Info
                      info:
                        labelsFromPath:
                          reason: [status, reason]
                          pull_request: [status, pullRequest]
                  - name: usage_tokens
                    help: "status.usage.tokens as the meter reported it"
                    each:
                      type: Gauge
                      gauge:
                        path: [status, usage, tokens]
                        nilIsZero: true
                  - name: budget_max_tokens
                    help: "spec.budget.maxTokens"
                    each:
                      type: Gauge
                      gauge:
                        path: [spec, budget, maxTokens]
                  - name: started_timestamp_seconds
                    help: "status.startedAt"
                    each:
                      type: Gauge
                      gauge:
                        path: [status, startedAt]
                        nilIsZero: true
                  - name: finished_timestamp_seconds
                    help: "status.finishedAt"
                    each:
                      type: Gauge
                      gauge:
                        path: [status, finishedAt]
                        nilIsZero: true
```

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; `Invalid: 0, Skipped: 0`. `render-bundle.py` resolves `valuesFrom`, so the rendered
kube-state-metrics Deployment carries `--custom-resource-state-config-file`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): kube-state-metrics series for AgentRun state"
```

### Task 2.5a: The run's tier reaches the metrics (further review, 2026-09-29; O23)

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml` (`agentrun_info`'s `labelsFromPath`)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Consumes: the claim label `agents.ogenki.io/tier` (`light`, `standard` or `frontier`), which SP3's
  `runs.Build` writes (SP3 Tasks 1.5a, 4.2a).
- Produces: `agentrun_info{…, tier}`. The label is empty for runs `task agent:run` creates.

- [ ] **Step 1: Write the failing test**

Add to `check_ksm`:

```python
    info = metrics.get("info", {}).get("info", {}).get("labelsFromPath", {})
    check(info.get("tier") == ["metadata", "labels", "agents.ogenki.io/tier"], "agentrun_info carries the run's tier (O23)")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, `agentrun_info carries the run's tier (O23)`.

- [ ] **Step 3: Implement**

In the `info` metric's `labelsFromPath`, after `branch: [status, branch]`:

```yaml
                          # SP3's triage tier (R47): fixed per run, empty for task agent:run.
                          tier: [metadata, labels, agents.ogenki.io/tier]
```

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/victoria-metrics-k8s-stack/vm-common-helm-values-configmap.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the run's tier on agentrun_info"
```

### Task 2.6: The "Agent run" dashboard

**Files:**
- Create: `observability/base/agent-platform/grafana-dashboard-agent-run.yaml`
- Modify: `observability/base/agent-platform/kustomization.yaml`
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Consumes: `agentrun_*` (Task 2.5), `agent.run_id` and `service.name=agent-harness` (Task 2.2),
  `agent.principal` (Task 2.4), the gateway metrics and access log (SP1).
- Produces: `uid: agent-run`, variable `run`. The fleet page (Task 2.7) and `task agent:run`
  (Task 2.8) link to `/d/agent-run/agent-run?var-run=<runId>`.

- [ ] **Step 1: Write the failing test**

Add to the suite:

```python
DASHBOARDS = "observability/base/agent-platform"


def dashboard(rel, name):
    d = find(rel, "GrafanaDashboard", name)
    check(not re.search(r"(?<!\$)\$\{", (ROOT / rel).read_text()), f"{rel}: every ${{…}} is written $${{…}} for Flux")
    check(d.get("spec", {}).get("folderRef") == "agents", f"{rel}: in the agents folder (O10)")
    try:
        return json.loads(d.get("spec", {}).get("json", "{}").replace("$${", "${"))
    except json.JSONDecodeError as exc:
        errors.append(f"{rel}: invalid JSON: {exc}")
        return {}


def titled(board):
    return {p["title"]: p for p in board.get("panels", [])}


def check_run_dashboard():
    board = dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-run.yaml", "agent-run")
    check(board.get("uid") == "agent-run", "uid agent-run: task agent:run, SP2 and SP3 link to it")
    check("run" in [v["name"] for v in board.get("templating", {}).get("list", [])], "a `run` variable")
    panels = titled(board)
    want = {"Run", "Duration", "Tokens vs budget", "Phase", "Step log", "Model calls through agent-router",
            "MCP calls", "Errors", "Tokens in / out", "Cost (USD)", "Model latency p50 / p95", "Error rate",
            "Steps", "Trace (agent-harness)", "agent-router spans"}
    check(want <= set(panels), f"missing panels: {sorted(want - set(panels))}")
    for title in ("Trace (agent-harness)", "agent-router spans"):
        check(panels.get(title, {}).get("datasource") == {"type": "jaeger", "uid": "VictoriaTraces"}, f"{title} reads VictoriaTraces")
    for title in ("Step log", "Model calls through agent-router", "MCP calls", "Errors", "Steps"):
        check(panels.get(title, {}).get("datasource", {}).get("type") == "victoriametrics-logs-datasource", f"{title} reads VictoriaLogs")
    targets = json.dumps([t for p in board.get("panels", []) for t in p.get("targets", [])])
    check('run_id=\\"${run}\\"' in targets and "xplane-run-${run}" in targets and "agent.run_id=${run}" in targets,
          "the panels filter on the run: KSM run_id, the pod and principal, the span tag")
```

and `CHECKS = [check_collector, check_router, check_ksm, check_run_dashboard]`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, a `FileNotFoundError` for `grafana-dashboard-agent-run.yaml`.

- [ ] **Step 3: The dashboard**

`observability/base/agent-platform/grafana-dashboard-agent-run.yaml`:

```yaml
---
# One agent run (agent observability design). `run` is the runId. Every panel filters on it:
# - kube-state-metrics' agentrun_* series (run_id);
# - the run pod's step log (xplane-run-<runId>);
# - agent-router's access log and gen_ai metrics (x_ar_agent / ar_agent = the run's ServiceAccount);
# - the run's spans in VictoriaTraces (agent.run_id; agent.principal on agent-router's).
# Tokens read the gateway counter on SP1; status.usage joins once a meter writes it (O7).
# $${…} survives Flux's postBuild substitution; bare $__range does too.
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: agent-run
  namespace: observability
spec:
  allowCrossNamespaceImport: true
  folderRef: "agents"
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Agent run",
      "uid": "agent-run",
      "schemaVersion": 39,
      "time": {"from": "now-6h", "to": "now"},
      "links": [{"title": "Agent fleet", "type": "link", "url": "/d/agent-fleet/agent-fleet", "keepTime": true}],
      "templating": {"list": [
        {"name": "datasource", "type": "datasource", "query": "prometheus"},
        {"name": "logs_datasource", "type": "datasource", "query": "victoriametrics-logs-datasource"},
        {"name": "run", "label": "Run", "type": "query", "refresh": 2, "sort": 1,
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "definition": "label_values(agentrun_info{namespace=\"agents\"}, run_id)",
         "query": "label_values(agentrun_info{namespace=\"agents\"}, run_id)"}
      ]},
      "panels": [
        {"id": 1, "type": "table", "title": "Run",
         "gridPos": {"x": 0, "y": 0, "w": 16, "h": 5},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [
           {"refId": "A", "instant": true, "format": "table", "expr": "topk(1, tlast_over_time(agentrun_info{namespace=\"agents\", run_id=\"$${run}\"}[$__range]))"},
           {"refId": "B", "instant": true, "format": "table", "expr": "max by (run_id, phase) (last_over_time(agentrun_status_phase{namespace=\"agents\", run_id=\"$${run}\"}[$__range]) == 1)"},
           {"refId": "C", "instant": true, "format": "table", "expr": "topk(1, tlast_over_time(agentrun_outcome_info{namespace=\"agents\", run_id=\"$${run}\"}[$__range]))"}
         ],
         "transformations": [
           {"id": "merge", "options": {}},
           {"id": "filterFieldsByName", "options": {"include": {"names": ["run_id", "role", "data_class", "principal", "repository", "model", "branch", "phase", "reason", "pull_request"]}}}
         ],
         "fieldConfig": {"defaults": {}, "overrides": [
           {"matcher": {"id": "byName", "options": "pull_request"}, "properties": [{"id": "links", "value": [{"title": "Pull request", "url": "$${__value.text}", "targetBlank": true}]}]},
           {"matcher": {"id": "byName", "options": "branch"}, "properties": [{"id": "links", "value": [{"title": "Pull requests from this branch", "url": "https://github.com/$${__data.fields.repository}/pulls?q=is%3Apr+head%3A$${__value.text}", "targetBlank": true}]}]}
         ]}},
        {"id": 2, "type": "stat", "title": "Duration",
         "gridPos": {"x": 16, "y": 0, "w": 4, "h": 5},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "fieldConfig": {"defaults": {"unit": "s"}, "overrides": []},
         "targets": [{"refId": "A", "instant": true, "expr": "(max(last_over_time(agentrun_finished_timestamp_seconds{namespace=\"agents\", run_id=\"$${run}\"}[$__range])) > 0 or vector(time())) - (max(last_over_time(agentrun_started_timestamp_seconds{namespace=\"agents\", run_id=\"$${run}\"}[$__range])) > 0)"}]},
        {"id": 3, "type": "stat", "title": "Tokens vs budget",
         "gridPos": {"x": 20, "y": 0, "w": 4, "h": 5},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "textMode": "value_and_name"},
         "targets": [
           {"refId": "A", "instant": true, "legendFormat": "gateway", "expr": "sum(increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", gen_ai_token_type=~\"input|output\"}[$__range]))"},
           {"refId": "B", "instant": true, "legendFormat": "status.usage", "expr": "max(last_over_time(agentrun_usage_tokens{namespace=\"agents\", run_id=\"$${run}\"}[$__range]))"},
           {"refId": "C", "instant": true, "legendFormat": "maxTokens", "expr": "max(last_over_time(agentrun_budget_max_tokens{namespace=\"agents\", run_id=\"$${run}\"}[$__range]))"}
         ]},
        {"id": 4, "type": "state-timeline", "title": "Phase",
         "gridPos": {"x": 0, "y": 5, "w": 24, "h": 4},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "legendFormat": "{{phase}}", "expr": "max by (phase) (agentrun_status_phase{namespace=\"agents\", run_id=\"$${run}\"} == 1)"}]},
        {"id": 5, "type": "logs", "title": "Step log",
         "gridPos": {"x": 0, "y": 9, "w": 24, "h": 10},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [{"refId": "A", "queryType": "instant", "expr": "kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$${run}\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run\""}]},
        {"id": 6, "type": "logs", "title": "Model calls through agent-router",
         "gridPos": {"x": 0, "y": 19, "w": 12, "h": 8},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [{"refId": "A", "queryType": "instant", "expr": "kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:\"agent-system\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$${run}\" AND log.path:~\"chat/completions\""}]},
        {"id": 7, "type": "logs", "title": "MCP calls",
         "gridPos": {"x": 12, "y": 19, "w": 12, "h": 8},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [{"refId": "A", "queryType": "instant", "expr": "kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:\"agent-system\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$${run}\" AND log.path:~\"mcp\""}]},
        {"id": 8, "type": "logs", "title": "Errors",
         "gridPos": {"x": 0, "y": 27, "w": 24, "h": 6},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [
           {"refId": "A", "queryType": "instant", "expr": "kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$${run}\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run error\""},
           {"refId": "B", "queryType": "instant", "expr": "kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:\"agent-system\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$${run}\" AND log.response_code:~\"^[45]\""}
         ]},
        {"id": 9, "type": "timeseries", "title": "Tokens in / out",
         "gridPos": {"x": 0, "y": 33, "w": 8, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "legendFormat": "{{gen_ai_token_type}}", "expr": "sum by (gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", gen_ai_token_type=~\"input|output\"}[$__rate_interval]))"}]},
        {"id": 10, "type": "stat", "title": "Cost (USD)",
         "gridPos": {"x": 8, "y": 33, "w": 4, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "fieldConfig": {"defaults": {"unit": "currencyUSD", "decimals": 4}, "overrides": []},
         "targets": [{"refId": "A", "instant": true, "expr": "sum(sum by (gen_ai_request_model, gen_ai_token_type) (increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", gen_ai_token_type=~\"input|output\"}[$__range])) * on (gen_ai_request_model, gen_ai_token_type) group_left() llm_gateway:price_usd_per_mtoken) / 1e6"}]},
        {"id": 11, "type": "timeseries", "title": "Model latency p50 / p95",
         "gridPos": {"x": 12, "y": 33, "w": 8, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "fieldConfig": {"defaults": {"unit": "s"}, "overrides": []},
         "targets": [
           {"refId": "A", "legendFormat": "p50", "expr": "histogram_quantile(0.5, sum by (le) (rate(gen_ai_server_request_duration_seconds_bucket{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\"}[$__rate_interval])))"},
           {"refId": "B", "legendFormat": "p95", "expr": "histogram_quantile(0.95, sum by (le) (rate(gen_ai_server_request_duration_seconds_bucket{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\"}[$__rate_interval])))"}
         ]},
        {"id": 12, "type": "stat", "title": "Error rate",
         "gridPos": {"x": 20, "y": 33, "w": 4, "h": 4},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "fieldConfig": {"defaults": {"unit": "percentunit"}, "overrides": []},
         "targets": [{"refId": "A", "instant": true, "expr": "(sum(increase(gen_ai_server_request_duration_seconds_count{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\", error_type=~\".+\"}[$__range])) or vector(0)) / sum(increase(gen_ai_server_request_duration_seconds_count{ar_agent=\"system:serviceaccount:agents:xplane-run-$${run}\"}[$__range]))"}]},
        {"id": 13, "type": "stat", "title": "Steps",
         "gridPos": {"x": 20, "y": 37, "w": 4, "h": 4},
         "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"},
         "targets": [{"refId": "A", "queryType": "stats", "expr": "kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$${run}\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run step \" | stats count() as steps"}]},
        {"id": 14, "type": "table", "title": "Trace (agent-harness)",
         "gridPos": {"x": 0, "y": 41, "w": 24, "h": 7},
         "datasource": {"type": "jaeger", "uid": "VictoriaTraces"},
         "targets": [{"refId": "A", "queryType": "search", "service": "agent-harness", "tags": "agent.run_id=$${run}", "limit": 20}]},
        {"id": 15, "type": "table", "title": "agent-router spans",
         "gridPos": {"x": 0, "y": 48, "w": 24, "h": 7},
         "datasource": {"type": "jaeger", "uid": "VictoriaTraces"},
         "targets": [{"refId": "A", "queryType": "search", "service": "agent-router", "tags": "agent.principal=system:serviceaccount:agents:xplane-run-$${run}", "limit": 50}]}
      ]
    }
```

Add `- grafana-dashboard-agent-run.yaml` to the kustomization.

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; exit 0; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/agent-platform scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the Agent run dashboard"
```

### Task 2.6a: The run page shows the tier, and a step line links to its trace (further review, 2026-09-29; O22, O23)

**Files:**
- Modify: `observability/base/agent-platform/grafana-dashboard-agent-run.yaml` (panel 1's `filterFieldsByName`, panel 5's `expr`)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Consumes: `agentrun_info{tier}` (Task 2.5a); step lines ending `| trace_id=<32 hex>` (Task 2.8a); the
  VictoriaLogs datasource's existing derived field "TraceID". That field is `matcherType: label` on
  `log.trace_id`, linking to `datasourceUid: VictoriaTraces`, in `observability/base/victoria-logs/grafana-datasource.yaml`.
  It is unchanged.

- [ ] **Step 1: Write the failing test**

```python
def check_run_trace_link():
    panels = titled(dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-run.yaml", "agent-run"))
    names = [n for tr in panels.get("Run", {}).get("transformations", []) if tr["id"] == "filterFieldsByName"
             for n in tr["options"]["include"]["names"]]
    check("tier" in names, "the run page shows the run's tier (O23)")
    step = json.dumps(panels.get("Step log", {}).get("targets", []))
    check("extract_regexp" in step and "rename trace_id as log.trace_id" in step,
          "a step line links to its trace through the log.trace_id derived field (O22)")
```

and append `check_run_trace_link` to `CHECKS`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, both messages.

- [ ] **Step 3: Implement**

- Panel 1 ("Run"): `filterFieldsByName`'s `names` gains `"tier"` after `"model"`.
- Panel 5 ("Step log"): its `expr` becomes:

```json
"expr": "kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$${run}\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run\" | extract_regexp \"trace_id=(?P<trace_id>[0-9a-f]{32})\" | rename trace_id as log.trace_id"
```

The header comment gains the line: `# A step line's trace_id becomes log.trace_id, which the VictoriaLogs datasource links to
# VictoriaTraces: correlation only (O22), the panels still filter on the pod.`

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; exit 0; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/agent-platform/grafana-dashboard-agent-run.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the run's tier, and a step line's trace link, on the run page"
```

### Task 2.7: The "Agent fleet" dashboard (SO-1's one click)

**Files:**
- Create: `observability/base/agent-platform/grafana-dashboard-agent-fleet.yaml`
- Modify: `observability/base/agent-platform/kustomization.yaml`
- Test: `scripts/ci/tests/test-agent-observability.py`

- [ ] **Step 1: Write the failing test**

```python
def check_fleet_dashboard():
    board = dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-fleet.yaml", "agent-fleet")
    check(board.get("uid") == "agent-fleet", "uid agent-fleet")
    panels = titled(board)
    check({"Runs", "Runs by phase", "Tokens per run", "Trace pipeline (agent-traces-collector)"} <= set(panels), "the fleet panels")
    links = json.dumps(panels.get("Runs", {}).get("fieldConfig", {}))
    check("/d/agent-run/agent-run?var-run=${__value.text}" in links, "one click from a run_id opens its Agent run page (SO-1)")
```

and `CHECKS = [check_collector, check_router, check_ksm, check_run_dashboard, check_fleet_dashboard]`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, a `FileNotFoundError` for `grafana-dashboard-agent-fleet.yaml`.

- [ ] **Step 3: The dashboard**

`observability/base/agent-platform/grafana-dashboard-agent-fleet.yaml`:

```yaml
---
# Every agent run in the time range, one row each (agent observability design). A run_id
# opens its "Agent run" page. "Agent platform" stays the capacity view the alerts link to
# (O9). The collector's panel is how a stalled trace pipeline is noticed (O16). Tokens read
# the gateway counter, keyed back to run_id by label_replace ($1 passes Flux untouched).
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: agent-fleet
  namespace: observability
spec:
  allowCrossNamespaceImport: true
  folderRef: "agents"
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Agent fleet",
      "uid": "agent-fleet",
      "schemaVersion": 39,
      "time": {"from": "now-7d", "to": "now"},
      "links": [{"title": "Agent platform", "type": "link", "url": "/d/agent-platform/agent-platform", "keepTime": true}],
      "templating": {"list": [
        {"name": "datasource", "type": "datasource", "query": "prometheus"}
      ]},
      "panels": [
        {"id": 1, "type": "table", "title": "Runs",
         "gridPos": {"x": 0, "y": 0, "w": 24, "h": 12},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [
           {"refId": "A", "instant": true, "format": "table", "expr": "topk by (run_id) (1, tlast_over_time(agentrun_info{namespace=\"agents\"}[$__range]))"},
           {"refId": "B", "instant": true, "format": "table", "expr": "max by (run_id, phase) (last_over_time(agentrun_status_phase{namespace=\"agents\"}[$__range]) == 1)"},
           {"refId": "C", "instant": true, "format": "table", "expr": "topk by (run_id) (1, tlast_over_time(agentrun_outcome_info{namespace=\"agents\"}[$__range]))"},
           {"refId": "D", "instant": true, "format": "table", "expr": "max by (run_id) (last_over_time(agentrun_started_timestamp_seconds{namespace=\"agents\"}[$__range]) > 0) * 1000"},
           {"refId": "E", "instant": true, "format": "table", "expr": "label_replace(sum by (ar_agent) (increase(gen_ai_client_token_usage_sum{ar_agent=~\"system:serviceaccount:agents:xplane-run-.*\", gen_ai_token_type=~\"input|output\"}[$__range])), \"run_id\", \"$1\", \"ar_agent\", \"system:serviceaccount:agents:xplane-run-(.*)\")"}
         ],
         "transformations": [
           {"id": "merge", "options": {}},
           {"id": "organize", "options": {"renameByName": {"Value #D": "started", "Value #E": "tokens"}}},
           {"id": "filterFieldsByName", "options": {"include": {"names": ["run_id", "role", "data_class", "principal", "phase", "reason", "pull_request", "started", "tokens"]}}},
           {"id": "sortBy", "options": {"sort": [{"field": "started", "desc": true}]}}
         ],
         "fieldConfig": {"defaults": {}, "overrides": [
           {"matcher": {"id": "byName", "options": "run_id"}, "properties": [{"id": "links", "value": [{"title": "Open this run", "url": "/d/agent-run/agent-run?var-run=$${__value.text}&$${__url_time_range}"}]}]},
           {"matcher": {"id": "byName", "options": "started"}, "properties": [{"id": "unit", "value": "dateTimeAsIso"}]},
           {"matcher": {"id": "byName", "options": "pull_request"}, "properties": [{"id": "links", "value": [{"title": "Pull request", "url": "$${__value.text}", "targetBlank": true}]}]}
         ]}},
        {"id": 2, "type": "timeseries", "title": "Runs by phase",
         "gridPos": {"x": 0, "y": 12, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "legendFormat": "{{phase}}", "expr": "sum by (phase) (agentrun_status_phase{namespace=\"agents\"} == 1)"}]},
        {"id": 3, "type": "timeseries", "title": "Tokens per run",
         "gridPos": {"x": 12, "y": 12, "w": 12, "h": 8},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "legendFormat": "{{ar_agent}}", "expr": "sum by (ar_agent) (rate(gen_ai_client_token_usage_sum{ar_agent=~\"system:serviceaccount:agents:.*\", gen_ai_token_type=~\"input|output\"}[$__rate_interval]))"}]},
        {"id": 4, "type": "timeseries", "title": "Trace pipeline (agent-traces-collector)",
         "gridPos": {"x": 0, "y": 20, "w": 24, "h": 6},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [
           {"refId": "A", "legendFormat": "accepted", "expr": "sum(rate(otelcol_receiver_accepted_spans_total{job=\"agent-traces-collector\"}[$__rate_interval]))"},
           {"refId": "B", "legendFormat": "refused", "expr": "sum(rate(otelcol_receiver_refused_spans_total{job=\"agent-traces-collector\"}[$__rate_interval]))"},
           {"refId": "C", "legendFormat": "exported", "expr": "sum(rate(otelcol_exporter_sent_spans_total{job=\"agent-traces-collector\"}[$__rate_interval]))"},
           {"refId": "D", "legendFormat": "export failed", "expr": "sum(rate(otelcol_exporter_send_failed_spans_total{job=\"agent-traces-collector\"}[$__rate_interval]))"}
         ]}
      ]
    }
```

Add `- grafana-dashboard-agent-fleet.yaml` to the kustomization.

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; exit 0; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/agent-platform scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): the Agent fleet dashboard"
```

### Task 2.7a: Tier chosen vs spend, on the fleet page (further review, 2026-09-29; O23, O24)

**Files:**
- Modify: `observability/base/agent-platform/grafana-dashboard-agent-fleet.yaml` (`templating`, two panels)
- Test: `scripts/ci/tests/test-agent-observability.py`

**Interfaces:**
- Consumes:
  - `agentrun_info{tier}` (Task 2.5a);
  - the gateway counter keyed back to `run_id`, as the "Runs" panel does;
  - step lines in VictoriaLogs, keyed on the pod name `xplane-run-<run_id>`.

- [ ] **Step 1: Write the failing test**

```python
def check_fleet_tier():
    panels = titled(dashboard(f"{DASHBOARDS}/grafana-dashboard-agent-fleet.yaml", "agent-fleet"))
    check({"Tier vs tokens and steps per run", "Tokens by tier"} <= set(panels), "tier vs spend panels (O23)")
    targets = json.dumps(panels.get("Tier vs tokens and steps per run", {}).get("targets", []))
    check("stats by (run_id) count() as steps" in targets and "agentrun_info" in targets,
          "tier, tokens and steps joined on run_id")
```

and append `check_fleet_tier` to `CHECKS`.

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-agent-observability.py; echo "exit $?"`
Expected: `exit 1`, `tier vs spend panels (O23)`.

- [ ] **Step 3: Implement**

`templating.list` gains `{"name": "logs_datasource", "type": "datasource", "query":
"victoriametrics-logs-datasource"}`. `panels` gains, after panel 4:

```json
        {"id": 5, "type": "table", "title": "Tier vs tokens and steps per run",
         "gridPos": {"x": 0, "y": 26, "w": 16, "h": 10},
         "datasource": {"type": "datasource", "uid": "-- Mixed --"},
         "targets": [
           {"refId": "A", "datasource": {"type": "prometheus", "uid": "$${datasource}"}, "instant": true, "format": "table", "expr": "max by (run_id, tier) (last_over_time(agentrun_info{namespace=\"agents\", tier!=\"\"}[$__range]))"},
           {"refId": "B", "datasource": {"type": "prometheus", "uid": "$${datasource}"}, "instant": true, "format": "table", "expr": "label_replace(sum by (ar_agent) (increase(gen_ai_client_token_usage_sum{ar_agent=~\"system:serviceaccount:agents:xplane-run-.*\", gen_ai_token_type=~\"input|output\"}[$__range])), \"run_id\", \"$1\", \"ar_agent\", \"system:serviceaccount:agents:xplane-run-(.*)\")"},
           {"refId": "C", "datasource": {"type": "victoriametrics-logs-datasource", "uid": "$${logs_datasource}"}, "queryType": "stats", "expr": "kubernetes.pod_namespace:\"agents\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run step \" | extract \"xplane-run-<run_id>\" from kubernetes.pod_name | stats by (run_id) count() as steps"}
         ],
         "transformations": [
           {"id": "merge", "options": {}},
           {"id": "organize", "options": {"renameByName": {"Value #B": "tokens"}}},
           {"id": "filterFieldsByName", "options": {"include": {"names": ["run_id", "tier", "tokens", "steps"]}}},
           {"id": "sortBy", "options": {"sort": [{"field": "tokens", "desc": true}]}}
         ]},
        {"id": 6, "type": "bargauge", "title": "Tokens by tier",
         "gridPos": {"x": 16, "y": 26, "w": 8, "h": 10},
         "datasource": {"type": "prometheus", "uid": "$${datasource}"},
         "targets": [{"refId": "A", "instant": true, "legendFormat": "{{tier}}", "expr": "sum by (tier) (label_replace(sum by (ar_agent) (increase(gen_ai_client_token_usage_sum{ar_agent=~\"system:serviceaccount:agents:xplane-run-.*\", gen_ai_token_type=~\"input|output\"}[$__range])), \"run_id\", \"$1\", \"ar_agent\", \"system:serviceaccount:agents:xplane-run-(.*)\") * on (run_id) group_left (tier) max by (run_id, tier) (last_over_time(agentrun_info{namespace=\"agents\", tier!=\"\"}[$__range])))"}]}
```

The header comment gains: `# Tier vs spend (O23): one tier per run, never re-routed within it (O24, SP3 R47).`

- [ ] **Step 4: Run the suite and the gates**

Run: `python3 scripts/ci/tests/test-agent-observability.py && python3 scripts/ci/flux-schema/check-substitution.py && export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`; exit 0; `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add observability/base/agent-platform/grafana-dashboard-agent-fleet.yaml scripts/ci/tests/test-agent-observability.py
git commit -m "feat(observability): tier chosen vs tokens and steps, on the fleet page"
```

### Task 2.8: `task agent:run` prints the run's page on stderr (SO-5, O17)

**Files:**
- Modify: `scripts/ops/k8s/agent-run.sh` (header comment; before `kubectl create`; before the final `echo`)
- Test: `scripts/ci/tests/test-agent-run.sh` (the kubectl stub; new cases before the summary)

**Interfaces:**
- Consumes: `uid: agent-run`, variable `run` (Task 2.6); HTTPRoute `grafana` in `observability`.
- Produces: stderr line `agent-run: dashboard <grafana>/d/agent-run/agent-run?var-run=<runId>&from=<epoch ms>&to=now`.
  The last stdout line is still `xplane-run-<runId>`.

- [ ] **Step 1: Write the failing tests**

In `test-agent-run.sh`, the stub answers `get` before recording anything:

```bash
cat >"$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# `get httproute` answers the Grafana host the dashboard link is built from (SO-5).
if [ "$1" = get ]; then printf '%s' "${STUB_HOST:-}"; exit 0; fi
printf '%s\n' "$*" >"$STUB_ARGS"
cat >"$STUB_CLAIM"
[ "${STUB_FAIL:-0}" = "1" ] && exit 1
exit 0
STUB
```

Before `[ "$fails" -eq 0 ] || exit 1`:

```bash
# SO-5: the run's page goes to stderr, so `| tail -1` still yields the run's name.
out="$(AGENT_GRAFANA_URL=https://grafana.example bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err")"
[ "$out" = "$(jq -r .metadata.name "$STUB_CLAIM")" ] || fail "stdout is still only the run's name"
run_id="$(jq -r '.metadata.name | sub("^xplane-run-"; "")' "$STUB_CLAIM")"
grep -qE "^agent-run: dashboard https://grafana\.example/d/agent-run/agent-run\?var-run=${run_id}&from=[0-9]{13}&to=now$" "$tmp/err" \
  || fail "stderr carries the run's dashboard link"
STUB_HOST=grafana.stub.example bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err" >/dev/null
grep -q 'agent-run: dashboard https://grafana.stub.example/d/agent-run/agent-run?var-run=' "$tmp/err" \
  || fail "without AGENT_GRAFANA_URL the host comes from the grafana HTTPRoute"
bash "$SUBJECT" --role implementer --class public --task x 2>"$tmp/err" >/dev/null || fail "no Grafana host is not an error"
grep -q 'agent-run: dashboard' "$tmp/err" && fail "no host, no link"
AGENT_GRAFANA_URL=https://grafana.example bash "$SUBJECT" --role implementer --class public --task x --dry-run 2>"$tmp/err" >/dev/null
grep -q 'agent-run: dashboard' "$tmp/err" && fail "a dry run creates no run, so it prints no link"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-agent-run.sh; echo "exit $?"`
Expected: `exit 1`, with `FAIL  stderr carries the run's dashboard link` and `FAIL  without
AGENT_GRAFANA_URL the host comes from the grafana HTTPRoute`. Every earlier case still passes.

- [ ] **Step 3: Implement**

In `agent-run.sh`, the header's last two lines become:

```bash
# Only the run's name goes to stdout (callers capture it with `| tail -1`); the
# applied claim's key fields and the run's dashboard link go to stderr (SO-5).
# AGENT_GRAFANA_URL overrides the Grafana host, read otherwise from the grafana HTTPRoute.
```

Before `# JSON, not YAML`:

```bash
# The run's page opens a minute before the run exists (epoch ms).
from_ms="$(( $(date +%s) - 60 ))000"
```

Between the stderr `printf` of the claim's fields and `echo "xplane-run-$run_id"`:

```bash
# The run's page (observability plan O17). No host, no link; a dry run creates no run.
if [ -z "$dry" ]; then
  grafana="${AGENT_GRAFANA_URL:-}"
  if [ -z "$grafana" ]; then
    host="$(kubectl get httproute grafana -n observability -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null || true)"
    [ -z "$host" ] || grafana="https://$host"
  fi
  [ -z "$grafana" ] || printf 'agent-run: dashboard %s/d/agent-run/agent-run?var-run=%s&from=%s&to=now\n' "${grafana%/}" "$run_id" "$from_ms" >&2
fi
```

- [ ] **Step 4: Run the suite, and shellcheck**

Run: `bash scripts/ci/tests/test-agent-run.sh && shellcheck scripts/ops/k8s/agent-run.sh`
Expected: `PASS`; shellcheck exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/ops/k8s/agent-run.sh scripts/ci/tests/test-agent-run.sh
git commit -m "feat(ops): task agent:run prints the run's dashboard link on stderr"
```

### Task 2.8a: The harness roots the run's trace, and its step log carries the trace id (further review, 2026-09-29; O21, O22)

This replaces Task 3.6: Task 0.5 verified the root-span loss.

**Files:**
- Modify: `container-images/agent-harness/agent_run.py`, `container-images/agent-harness/Dockerfile` (`AGENT_HARNESS_VERSION=v0.1.2`)
- Test: `container-images/agent-harness/tests/test_agent_run.py`
- Modify (crossplane-configuration, on CC-O1): `apis/agentrun/kcl/main.k` (`_HARNESS_PROFILES.openhands.image`), `tests/golden/agentrun-{basic,complete}.yaml`

**Interfaces:**
- Consumes:
  - `TRACEPARENT` (Task 1.3a);
  - `OTEL_EXPORTER_OTLP_ENDPOINT` (Task 1.3);
  - agent-server's `DELETE /api/conversations/{id}`;
  - lmnr's `LMNR_SPAN_CONTEXT` (Task 0.5).
- Produces:
  - `agent_run.start_run_span(env, exporter=None) -> (span, provider, extra_env)`. `extra_env` is
    `{"LMNR_SPAN_CONTEXT", "OTEL_BSP_SCHEDULE_DELAY"}`. It returns `(None, None, {})` without an
    endpoint.
  - `agent_run.close_conversation(cid)`, `agent_run.BSP_DELAY_MS = "1000"`, `agent_run.FLUSH_WAIT_S = 2`.
  - `StepLog(cid, trace_id="")`: step lines end with ` | trace_id=<32 hex>` when it is set.
  - The span `agent-run`, root of a `task agent:run` run's trace, or the child of the factory's task span.
  - Harness `v0.1.2`, `v0.1.2-pr<O-1>.<sha8>` until the wave.

- [ ] **Step 1: Write the failing tests**

Add `import uuid` to the test module's imports, and append:

```python
class TraceTest(unittest.TestCase):
    """Observability plan O21-O23: the run's root span, its parent, and the step log's trace id."""

    TP = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

    def span(self, env):
        from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter
        exporter = InMemorySpanExporter()
        span, provider, extra = agent_run.start_run_span(env, exporter=exporter)
        span.end()
        provider.shutdown()
        [got] = exporter.get_finished_spans()
        return got, extra

    def test_the_run_span_joins_the_trigger_trace(self):
        got, extra = self.span({"TRACEPARENT": self.TP})
        self.assertEqual(got.name, "agent-run")
        self.assertEqual(format(got.context.trace_id, "032x"), "4bf92f3577b34da6a3ce929d0e0e4736")
        self.assertEqual(format(got.parent.span_id, "016x"), "00f067aa0ba902b7")
        ctx = json.loads(extra["LMNR_SPAN_CONTEXT"])
        # agent-server's own root span becomes this span's child (Task 0.5)
        self.assertEqual(uuid.UUID(ctx["trace_id"]).int, got.context.trace_id)
        self.assertEqual(uuid.UUID(ctx["span_id"]).int, got.context.span_id)
        self.assertEqual(extra["OTEL_BSP_SCHEDULE_DELAY"], agent_run.BSP_DELAY_MS)

    def test_no_or_a_bad_traceparent_starts_a_fresh_trace(self):
        for env in ({}, {"TRACEPARENT": "00-zz-1"}, {"TRACEPARENT": "01" + self.TP[2:]}):
            got, _ = self.span(env)
            self.assertIsNone(got.parent, env)
            self.assertNotEqual(format(got.context.trace_id, "032x"), "4bf92f3577b34da6a3ce929d0e0e4736")

    def test_tracing_is_off_without_an_endpoint(self):
        self.assertEqual(agent_run.start_run_span({}), (None, None, {}))

    def test_step_lines_carry_the_trace_id(self):
        log = agent_run.StepLog("cid", "4bf92f3577b34da6a3ce929d0e0e4736")
        line = log.describe({"kind": "ActionEvent", "tool_name": "terminal", "summary": "s", "action": {"command": "ls"}})
        self.assertEqual(line, "agent-run step 1: terminal | s | ls | trace_id=4bf92f3577b34da6a3ce929d0e0e4736")
        self.assertEqual(agent_run.StepLog("cid").describe({"kind": "ActionEvent", "tool_name": "t", "summary": "s", "action": {}}),
                         "agent-run step 1: t | s | ")

    def test_closing_the_conversation_flushes_the_root_span(self):
        with mock.patch.object(agent_run, "http") as http, mock.patch.object(agent_run.time, "sleep") as sleep:
            agent_run.close_conversation("cid")
        http.assert_called_once_with("DELETE", "/api/conversations/cid")
        sleep.assert_called_once_with(agent_run.FLUSH_WAIT_S)
        with mock.patch.object(agent_run, "http", side_effect=OSError("gone")), mock.patch.object(agent_run.time, "sleep"):
            agent_run.close_conversation("cid")  # never fails the run
```

- [ ] **Step 2: Run them to see them fail**

Run: `docker build --target test container-images/agent-harness`
Expected: the test stage fails with 5 errors:
- `AttributeError: module 'agent_run' has no attribute 'start_run_span'` (three tests);
- `… 'close_conversation'`;
- `TypeError: StepLog.__init__() takes 2 positional arguments but 3 were given`.

- [ ] **Step 3: Implement**

After H-1's `redact()` (`re` and `uuid` are already imported):

```python
# A W3C traceparent from the factory's task span (SP3 R46), handed over by the composition.
TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$")
# agent-server exports on a 5 s batch and nothing at exit, and its root span ends only when
# the conversation closes (observability plan, Task 0.5): a 1 s batch, a close, then a wait.
BSP_DELAY_MS = "1000"
FLUSH_WAIT_S = 2


def start_run_span(env: dict, exporter=None):
    """The run's root span and the env that makes agent-server's root span its child.

    Parented on TRACEPARENT when it is a valid W3C header, a fresh trace otherwise (the
    `task agent:run` path). (None, None, {}) when tracing is off. The trace id is correlation
    only: the collector stamps the run id from the connection (observability plan O22).
    """
    endpoint = env.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint and exporter is None:
        return None, None, {}
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor

    if exporter is None:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        exporter = OTLPSpanExporter(endpoint=endpoint.rstrip("/") + "/v1/traces")
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    parent = None
    m = TRACEPARENT.match(env.get("TRACEPARENT", ""))
    if m:
        remote = trace.SpanContext(int(m[1], 16), int(m[2], 16), is_remote=True,
                                   trace_flags=trace.TraceFlags(trace.TraceFlags.SAMPLED))
        parent = trace.set_span_in_context(trace.NonRecordingSpan(remote))
    span = provider.get_tracer("agent-run").start_span("agent-run", context=parent)
    sc = span.get_span_context()
    # lmnr's LaminarSpanContext: UUID-shaped ids; agent-server's spans parent on it.
    ctx = {"trace_id": str(uuid.UUID(int=sc.trace_id)), "span_id": str(uuid.UUID(int=sc.span_id)), "is_remote": True}
    return span, provider, {"LMNR_SPAN_CONTEXT": json.dumps(ctx), "OTEL_BSP_SCHEDULE_DELAY": BSP_DELAY_MS}


def close_conversation(cid: str) -> None:
    """Close the conversation, which ends the SDK's root span, and let the 1 s batch export it."""
    try:
        http("DELETE", "/api/conversations/" + cid)
    except Exception as exc:  # noqa: BLE001 -- tracing must never fail the run
        print("agent-run: conversation not closed: %s" % exc, file=sys.stderr, flush=True)
    time.sleep(FLUSH_WAIT_S)
```

In `StepLog`:
- `__init__(self, cid: str, trace_id: str = "")` sets `self.trace_id = trace_id`;
- the `ActionEvent` branch becomes:

```python
            line = "agent-run step %d: %s | %s | %s" % (self.steps, tool, _short(event.get("summary"), 120), _short(target, 200))
            # Correlation only (O22): links the line to its trace in Grafana, attributes nothing.
            return line + (" | trace_id=" + self.trace_id if self.trace_id else "")
```

In `main()`:

1. `server = subprocess.Popen(…)` becomes:

   ```python
       span, provider, trace_env = start_run_span(env)
       trace_id = format(span.get_span_context().trace_id, "032x") if span else ""
       server = subprocess.Popen(SERVER_CMD, cwd="/", env=server_env({**env, **trace_env}))
   ```

2. `StepLog(conversation["id"])` becomes `StepLog(conversation["id"], trace_id)`.
3. The inner `finally` ends with `if span: close_conversation(conversation["id"])`.
4. After the revoke in the outer `finally`: `if span: span.end(); provider.shutdown()`, on two lines.

In the Dockerfile, `ARG AGENT_HARNESS_VERSION=v0.1.2`, with the comment `# O-1 (observability plan
O21): after H-1's v0.1.1.`

- [ ] **Step 4: Run every harness suite**

Run: `docker build --target test container-images/agent-harness`
Expected: exit 0. The five `TraceTest` tests are `ok`, and every other suite is `OK`. This was
verified 2026-09-29 on SP1's harness source: 36 tests OK.

- [ ] **Step 5: Commit, push the pre-release, pin it in CC-O1**

```bash
git add container-images/agent-harness
git commit -m "feat(agent-harness): root the run's trace and carry its id in the step log"
git push
PR=$(gh pr view --json number --jq .number)
TAG="v0.1.2-pr${PR}.$(git rev-parse --short=8 HEAD)"
gh auth token | docker login ghcr.io -u Smana --password-stdin
docker build --platform linux/amd64 -t "ghcr.io/smana/agent-harness:${TAG}" container-images/agent-harness
docker push "ghcr.io/smana/agent-harness:${TAG}"
skopeo inspect --raw "docker://ghcr.io/smana/agent-harness:${TAG}" | sha256sum
```

If the push is denied, the gh token lacks `write:packages`, and [OWNER] runs the last four lines.
Then, on CC-O1:
1. set `_HARNESS_PROFILES.openhands.image` to `ghcr.io/smana/agent-harness:${TAG}@sha256:<digest>`,
   with the comment `# Observability plan O21: the run's root span, LMNR_SPAN_CONTEXT, trace_id in the step log.`;
2. re-render both goldens (Task 1.5 Step 2);
3. run `task check`, commit `fix(agentrun): pin harness v0.1.2 (trace root)` and push;
4. record the new package pre-release, and re-pin it on O-1 (Task 2.1 Step 3).

### Task 2.9: ADR-0051, the umbrella README and runbook 08's live steps

**Files:**
- Create: `website/content/docs/decisions/0051-otel-collector-agent-trace-gate.md`
- Modify: `website/content/docs/decisions/_index.md`, `clusters/aws-0-agent-platform/README.md`
- Modify: `docs/runbooks/agent-factory/08-observability.md` (Steps 6–10 and Results rows)

- [ ] **Step 1: ADR-0051**, from `template.md`:

```markdown
---
title: An OpenTelemetry Collector is the agent trace gate
linkTitle: 0051 · OTel Collector as the agent trace gate
weight: 510
description: Agent runs send spans to an OpenTelemetry Collector outside the sandbox. It stamps the run id from the sending pod's label and keeps only an allowlist of metadata attributes before VictoriaTraces, because the OpenHands SDK records prompts and tool output and cannot be configured not to.
lastVerified: 2026-09-27
---

**Status**: Accepted
**Date**: 2026-09-27
**Deciders**: Smana (Platform Owner)
**Related Spec**: `docs/superpowers/specs/2026-09-27-agent-observability-design.md`

---

## Context

The owner decided that agent traces carry metadata only: timing, model, token counts, tool names,
status and errors. The OpenHands SDK's Laminar instrumentation (lmnr 0.7.60) records prompts,
completions and tool input and output as span attributes, and lmnr hardcodes content tracing on. A
compromised run can also POST any span it likes. SPEC-006 (CL-1) declined a collector for the AI
gateway's traces, so this reverses that stance for agent traces.

---

## Decision Drivers

- The control must sit outside the sandbox.
- The run id must come from something a run cannot forge.
- Envoy Gateway 1.9 exports OTLP/gRPC only, and VictoriaTraces ingests OTLP/HTTP.
- As few new moving parts as the control allows.

---

## Considered Options

### Option 1: OpenTelemetry Collector (k8s distribution) in `observability`

**Pros**:
- `redaction` is an allowlist that fails closed, over resource, span and event attributes;
- `k8s_attributes` stamps the run id from the connection's pod;
- it takes both OTLP/HTTP and OTLP/gRPC.

**Cons**: one more Deployment and chart to keep current.

### Option 2: Filter in the harness, export to VictoriaTraces directly

**Pros**: no new component.

**Cons**:
- it is not a control, since a compromised run skips it;
- the SDK offers no switch, so the filter would monkeypatch lmnr internals;
- Envoy's gRPC spans would still need a receiver.

### Option 3: Vector's OTLP source (ADR-0030's log shipper)

**Pros**: already deployed.

**Cons**:
- trace support is its least exercised path;
- no pod-by-connection attribution;
- the log pipeline would carry a security control.

---

## Decision Outcome

**Chosen option**: "OpenTelemetry Collector".

**Rationale**: it is the only option where the attribute allowlist and the run id are both enforced
by something the sandbox cannot reach.

---

## Consequences

### Positive

- VictoriaTraces holds only allowlisted metadata for agent runs, whatever the SDK records.
- Envoy's and the harness's spans share one pipeline host.

### Negative

- A new metadata attribute is invisible until someone adds it to the allowlist.
- Content still crosses the pod network to the collector (WireGuard on aws-0) before it is dropped.

### Neutral

- The collector runs only under the opt-in `agent-platform` umbrella.

---

## Implementation Notes

`observability/base/agent-platform/agent-traces-collector.yaml`. The run CNP, composed by the
`AgentRun` composition in crossplane-configuration, admits `POST /v1/traces` on :4318 only. Proved
by `scripts/ci/tests/test-agent-traces-filter.sh` and runbook 08.

---

## References

- `docs/superpowers/plans/2026-09-27-agent-observability-plan.md` (rulings O1–O6)
- [ADR-0030]({{< relref "/docs/decisions/0030-vector-as-log-shipper.md" >}})
```

The index row, after the last existing one:

```markdown
| [0051]({{< relref "/docs/decisions/0051-otel-collector-agent-trace-gate.md" >}}) | An OpenTelemetry Collector is the agent trace gate: run id from the pod, metadata allowlist | Accepted | 2026-09-27 |
```

The References link to the plan points at a path that exists only once the plan is committed, and
`verify-doc-paths.sh` checks backticked paths. If the plan is not in the repo at gate time, the
reference is written without backticks.

- [ ] **Step 2: The umbrella README row**

In `clusters/aws-0-agent-platform/README.md`, the `agent-observability` row's *Holds* becomes: "VMRules,
the dashboards (`agent-platform`, `agent-run`, `agent-fleet`) and the agent trace collector".

- [ ] **Step 3: Runbook 08, Steps 6–10**

Append before `## Results`:

````markdown
## Per-run view (agent observability)

Proves SO-1…SO-5 of `docs/superpowers/specs/2026-09-27-agent-observability-design.md`. Two runs are
started here: A plants three markers that must never reach VictoriaTraces, and B stays up for the
network checks.

```bash
CA=opentofu/aws/openbao/management/.tls/ca.pem
VT=https://vt.priv.aws.ogenki.io
VL=https://vl.priv.aws.ogenki.io
VM="/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query"
vmq() { kubectl get --raw "$VM?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -c '.data.result'; }
R=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
```

### Step 6 — the platform pieces are up

```bash
kubectl get deploy -n observability agent-traces-collector -o jsonpath='{.status.readyReplicas}'; echo
kubectl logs -n observability deploy/agent-traces-collector | grep -ciE 'forbidden|cannot list'
POD=$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=agent-router -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system "pod/$POD" 19000:19000 >/dev/null & PF=$!; sleep 2
curl -s localhost:19000/config_dump | grep -c 'envoy.tracers.opentelemetry'; kill $PF
```

Expected: `1`; `0`; a positive count. A `forbidden` line means the Role is too narrow for
`k8s_attributes`: record it, and widen it to the chart preset's pods and namespaces get/list/watch as
a ClusterRole (Task 0.4 names this fallback).

### Step 7 — SO-5, and the two runs

```bash
task agent:run -- --role implementer --class public --task "Run \`echo TMARK-$R\` in the terminal. Then finish; your final message is exactly CMARK-$R. Never repeat this token: PMARK-$R." 2>/tmp/obs-err | tail -1 | tee /tmp/obs-a
grep '^agent-run: dashboard ' /tmp/obs-err
task agent:run -- --role implementer --class public --task "Run \`sleep 240; ls docs\` in the terminal, then finish." 2>/dev/null | tail -1 | tee /tmp/obs-b
A=$(sed 's/^xplane-run-//' /tmp/obs-a); B=$(sed 's/^xplane-run-//' /tmp/obs-b)
sleep 60; vmq "agentrun_status_phase{run_id=\"$A\"} == 1"
```

Expected: `tail -1` prints `xplane-run-<8 chars>` twice. `/tmp/obs-err` holds
`agent-run: dashboard https://grafana.priv.aws.ogenki.io/d/agent-run/agent-run?var-run=<A>&from=<13 digits>&to=now`.
The query returns one series whose `phase` is `Pending` or `Running` (Task 0.3's live half).

### Step 8 — SO-3: one trace, a span per model call, no content

Once A has ended (`kubectl wait agentrun/xplane-run-$A -n agents --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m`):

```bash
now=$(date +%s); tags=$(jq -rn --arg r "$A" '{"agent.run_id":$r}|tojson|@uri')
curl -s --cacert $CA "$VT/select/jaeger/api/traces?service=agent-harness&tags=$tags&limit=200&start=$(( (now-7200)*1000000 ))&end=$(( now*1000000 ))" > /tmp/obs-traces.json
jq '[.data[].traceID] | unique | length' /tmp/obs-traces.json
jq '[.data[].spans[] | select(.operationName | startswith("llm."))] | length' /tmp/obs-traces.json
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$A\" AND log.path:~\"chat/completions\" AND log.response_code:\"200\" | stats count() calls"
for m in PMARK TMARK CMARK; do printf '%s %s\n' $m "$(curl -s --cacert $CA "$VT/select/logsql/query" --data-urlencode "query=_time:2h \"$m-$R\"" | wc -l)"; done
curl -s --cacert $CA "$VT/select/logsql/query" --data-urlencode "query=_time:2h \"span_attr:agent.run_id\":\"$A\" \"span_attr:redaction.redacted.count\":>0 | stats count() spans"
curl -s --cacert $CA "$VT/select/logsql/field_names" --data-urlencode "query=_time:2h \"span_attr:agent.run_id\":\"$A\"" | jq -r '.values[].value' | grep 'attr:' | sed -E 's/^.*attr://' | sort -u > /tmp/obs-keys
python3 -c 'import yaml; hr=next(d for d in yaml.safe_load_all(open("observability/base/agent-platform/agent-traces-collector.yaml")) if d and d["kind"]=="HelmRelease"); ok=set(hr["spec"]["values"]["alternateConfig"]["processors"]["redaction"]["allowed_keys"])|{"redaction.redacted.count","redaction.masked.count"}; print("outside the allowlist:", sorted(set(open("/tmp/obs-keys").read().split())-ok) or "none")'
curl -s --cacert $CA "$VT/select/jaeger/api/traces?service=agent-router&tags=$(jq -rn --arg p "system:serviceaccount:agents:xplane-run-$A" '{"agent.principal":$p}|tojson|@uri')&limit=200&start=$(( (now-7200)*1000000 ))&end=$(( now*1000000 ))" | jq '[.data[].traceID] | unique'
```

Expected, in order:
- `1`, one trace. If more, see Task 0.1's fallback.
- A count equal to `calls`, a span per model call.
- `calls` itself.
- `PMARK 0`, `TMARK 0`, `CMARK 0`.
- `spans` > 0: content was sent and dropped, so the zero above is the filter's doing, not the SDK's silence.
- `outside the allowlist: none`.
- The router spans' trace ids equal the harness trace's id: `traceparent` survived identity-proxy.
  Other ids mean no join; the run page still finds them by `agent.principal` (O14).

The run's root is its `agent-run` span, and a `conversation` span is its child (Task 2.8a). If no
`conversation` span is among the run's spans, raise `FLUSH_WAIT_S` (Task 0.5's fallback).

### Step 9 — SO-4: the collector's traces path only

While B is `Running`:

```bash
COLL=$(kubectl get svc -n observability agent-traces-collector -o jsonpath='{.spec.clusterIP}')
VTIP=$(kubectl get svc -n observability victoria-traces-vt-single-server -o jsonpath='{.spec.clusterIP}')
kubectl exec -i -n agents xplane-run-$B -c harness -- /usr/local/bin/python - "$COLL" "$VTIP" <<'PY'
import socket, sys, urllib.error, urllib.request
coll, vt = sys.argv[1], sys.argv[2]
def post(url):
    req = urllib.request.Request(url, data=b'{"resourceSpans":[]}', method="POST", headers={"Content-Type": "application/json"})
    try:
        return urllib.request.urlopen(req, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:
        return type(e).__name__
base = "http://agent-traces-collector.observability.svc.cluster.local:4318"
print("traces", post(base + "/v1/traces"))
print("logs", post(base + "/v1/logs"))
s = socket.socket(); s.settimeout(5)
print("grpc", "open" if s.connect_ex((coll, 4317)) == 0 else "blocked")
print("victoriatraces", post("http://%s:10428/insert/opentelemetry/v1/traces" % vt))
PY
NODE=$(kubectl get pod -n agents xplane-run-$B -o jsonpath='{.spec.nodeName}')
CILIUM_POD=$(kubectl get pods -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system $CILIUM_POD -c cilium-agent -- hubble observe --from-pod agents/xplane-run-$B --to-namespace observability --last 50 -o compact
```

Expected:
- `traces 200`, `logs 403` (Cilium's L7 "Access denied"), `grpc blocked`, `victoriatraces` a
  timeout name (`URLError` or `TimeoutError`).
- Hubble shows `http-request FORWARDED (HTTP/1.1 POST …/v1/traces)`, `http-request DROPPED (HTTP/1.1
  POST …/v1/logs)`, and `Policy denied DROPPED` to :4317 and to :10428.
- If `traces` is `403` or times out, or Step 8 found no spans at all, Task 0.4's fallback applies.

### Step 10 — SO-1, SO-2, and the printer columns

```bash
kubectl annotate agentrun -n agents xplane-run-$A agents.ogenki.io/pull-request=https://github.com/Smana/cloud-native-ref/pull/<O-1 number> agents.ogenki.io/usage-tokens=12345
kubectl get agentrun -n agents
vmq "topk by (run_id) (1, tlast_over_time(agentrun_outcome_info{run_id=\"$A\"}[1h]))"
vmq "sum(increase(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$A\", gen_ai_token_type=~\"input|output\"}[2h]))"
vmq "max(agentrun_budget_max_tokens{run_id=\"$A\"})"
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$A\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run\"" | jq -r '."kubernetes.pod_name"' | sort | uniq -c
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$A\"" | jq -r '."log.x_ar_agent"' | sort | uniq -c
```

Expected:
- The header row reads `NAME ROLE CLASS PHASE BRANCH PRINCIPAL PR TOKENS REASON`, and A's row shows
  the PR URL and `12345`.
- The outcome series carries the `pull_request` label.
- Gateway tokens are > 0, and the budget is `2000000`.
- Both `uniq -c` outputs have exactly one line, A's pod and A's principal, though B ran at the same
  time (SO-2).

[OWNER]:
1. Open **Agent fleet** and click A's `run_id`.
2. **Agent run** must show the phase `Succeeded`, the reason (empty for a success), the PR link,
   gateway tokens against `maxTokens` 2000000, the step log with the `TMARK` command, the trace
   table, and a trace view whose `llm.*` spans carry token counts.
3. Record it under Results.

Tear down: `kubectl delete agentrun -n agents xplane-run-$A xplane-run-$B`.
````

Add these Results rows:

```markdown
| 6 — collector, router tracing | ready 1, 0 forbidden, tracer present | | |
| 7 — SO-5, KSM | name on the last line, link on stderr, A's phase series | | |
| 8 — SO-3 | 1 trace, spans = calls, markers 0 0 0, redacted > 0, none outside the allowlist | | |
| 9 — SO-4 | 200 / 403 / blocked / timeout; Hubble FORWARDED and DROPPED | | |
| 10 — SO-1, SO-2, columns | columns, PR, tokens, one pod and one principal; owner's click | | |
```

- [ ] **Step 4: Gates and commit**

Run: `./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh`
Expected: exit 0 both.

```bash
git add website/content/docs/decisions clusters/aws-0-agent-platform/README.md docs/runbooks/agent-factory/08-observability.md
git commit -m "docs(agents): ADR-0051, and runbook 08 steps for the per-run view"
```

### Task 2.10: Gates and O-1 as a draft

- [ ] **Step 1: Every gate**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-vmrules.sh && ./scripts/ci/validate-links.sh && ./scripts/ci/validate-doc-claims.sh && ./scripts/ci/verify-doc-paths.sh && python3 scripts/ci/flux-schema/check-substitution.py && task check`
Expected: all exit 0; `Invalid: 0, Skipped: 0`. The test runner lists `PASS  test-agent-observability`,
`PASS  test-agent-traces-filter` and `PASS  test-agent-run`.

- [ ] **Step 2: Open O-1 with `create-pr`**, as a draft on base `fix/agent-review-hardening`

Title: `feat(agents): per-run observability — trace collector, run and fleet dashboards`. The body:
- a mermaid diagram of the spec's data flow;
- the spec link and ADR-0051;
- CC-O1's link and its pinned pre-release;
- a "Spikes" section with Tasks 0.1–0.4's outcomes;
- the SP3 edit (Task 8.7 moved here);
- what it does not do: no alerts (O16), and harness content hygiene is partial (O6);
- an empty "Live evidence" section that Phase 3 fills.

Run: `gh pr checks <O-1> --watch`
Expected: every check green, `Kubernetes validation ☸` included, its log showing `==> Using pre-built
Crossplane XRD CRDs from`.

---

## Phase 3 — Live gates on gcp-0, after GCP parity Task 8.6

This phase waits for GCP parity Task 8.6 (GCP parity cross-plan edit, 2026-09-29; was "the next
aws-0 rebuild" — aws-0 is destroyed today). That is the same rebuild as SP2's Task 0.5.14 for H-1.
Every output goes into O-1's "Live evidence" and runbook 08's Results.

### Task 3.1: [LIVE] Deploy, and the platform checks

- [ ] **Step 1:** Run the live-check routine (PR map), steps 1–4.
- [ ] **Step 2: [OWNER]** The rebuild, from the `integration/agent-factory` checkout.
- [ ] **Step 3:** Run runbook 08 Step 6. Expected as written there.
  - This is the live half of Tasks 0.2 and 0.4: the router tracer is present, and the collector
    runs on its Role.
- [ ] **Step 4: No stray OTLP signals**, after Task 3.2's runs

Run: `kubectl logs -n observability deploy/agent-traces-collector | grep -ciE 'unmarshal|bad request|unsupported'`
Expected: `0`. Also look at Step 9's Hubble output for `/v1/logs` flows from a run's own harness,
besides the probe's: a `DROPPED` there means lmnr exports OTel log records. The CNP stops them, as
O19 intends; record it.

### Task 3.2: [LIVE] SO-5, and the canary runs

- [ ] **Step 1:** Run runbook 08 Step 7.
  - Expected as written there. This is SO-5 and the live half of Task 0.3.

### Task 3.3: [LIVE] SO-3

- [ ] **Step 1:** Run runbook 08 Step 8. Expected as written there.
- [ ] **Step 2:** If the run's spans hold no `conversation` span, apply Task 0.5's fallback. Task
  3.6 is superseded by Task 2.8a (O21).

### Task 3.3a: [LIVE] The trace root and the step log's trace link (further review, 2026-09-29; O21, O22)

This is the live half of Task 0.5, on SP1's path: `task agent:run`, no traceparent. SP3's factory
path is proved by SP3's Task 1.13a.

- [ ] **Step 1: One root, `agent-run`, and the conversation under it** (run A, Step 8's `/tmp/obs-traces.json`)

Run: `jq -r '.data[].spans[] | select((.references // []) | length == 0) | .operationName' /tmp/obs-traces.json; jq -r '[.data[].spans[] | {id: .spanID, name: .operationName}] as $s | .data[].spans[] | select(.operationName == "conversation") | .references[0].spanID as $p | $s[] | select(.id == $p) | .name' /tmp/obs-traces.json`
Expected: `agent-run`, then `agent-run`: the conversation's parent is the harness's root span.

- [ ] **Step 2: The step log names that trace**

```bash
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_name:\"xplane-run-$A\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run step \" | extract_regexp \"trace_id=(?P<trace_id>[0-9a-f]{32})\" | stats by (trace_id) count() lines"
jq -r '[.data[].traceID] | unique[]' /tmp/obs-traces.json
```

Expected: one row, its `trace_id` equal to the second command's single trace id, and `lines` equal to
the run's step count.

- [ ] **Step 3: [OWNER]** On run A's page, a step line shows "View Trace", and it opens that trace.
  Record both in O-1's "Live evidence".

### Task 3.4: [LIVE] SO-4

- [ ] **Step 1:** Run runbook 08 Step 9. Expected as written there.
- [ ] **Step 2:** If `traces` is not `200`, or Step 8 found no spans for A:
  1. Check the collector's view with
     `kubectl logs -n observability deploy/agent-traces-collector | grep -i 'pod_association\|no pod'`,
     and Hubble's source IP for the flow.
  2. If the source is the node, not the pod, apply Task 0.4's fallback: drop `rules.http` in CC-O1,
     re-run Task 1.5 and Tasks 2.1 and 3.1.
  3. Propose Δ1's L4 wording.

### Task 3.5: [LIVE] SO-1, SO-2, printer columns

- [ ] **Step 1:** Run runbook 08 Step 10, the [OWNER] click included. Expected as written there.

### Task 3.6: [LIVE, conditional] The root span is lost at shutdown (O13)

**Superseded, 2026-09-29.** Task 0.5 verified the loss offline, and Task 2.8a ships the fix
unconditionally (O21). This task is kept for its numbering only; do not run it.

Only if Task 3.3 Step 2 sends you here.

**Files:**
- Modify: `container-images/agent-harness/agent_run.py` (the `server.wait` in `main`'s `finally`), `container-images/agent-harness/Dockerfile` (`AGENT_HARNESS_VERSION`)
- Test: `container-images/agent-harness/tests/test_agent_run.py`

- [ ] **Step 1: Write the failing test**

In `test_agent_run.py`:

```python
class ShutdownGraceTest(unittest.TestCase):
    def test_agent_server_gets_time_to_export_its_spans(self):
        # Observability plan O13: agent-server ends the conversation's root span in its
        # lifespan shutdown and exports it at exit; 10 s lost it on aws-0. 25 s stays
        # inside the pod's 30 s grace period, before the revoke.
        self.assertEqual(agent_run.SERVER_STOP_GRACE_S, 25)
```

Run: `docker build --target test container-images/agent-harness`
Expected: the test stage fails, `AttributeError: … has no attribute 'SERVER_STOP_GRACE_S'`.

- [ ] **Step 2: Implement**

After `MAX_POLL_ERRORS`:

```python
# agent-server ends the conversation's root span on shutdown and exports it at exit
# (observability plan O13). Inside terminationGracePeriodSeconds (30 s), before the revoke.
SERVER_STOP_GRACE_S = 25
```

In `main`'s `finally`, `server.wait(10)` becomes `server.wait(SERVER_STOP_GRACE_S)`. In the Dockerfile,
`ARG AGENT_HARNESS_VERSION=v0.1.2`, with the comment `# O-1 (observability plan O13): after H-1's v0.1.1.`

- [ ] **Step 3: Test, build, push the pre-release, re-pin**

Run: `docker build --target test container-images/agent-harness`
Expected: exit 0.

Commit, then push the pre-release by hand. CI never pushes a PR build. It is amd64 only, the one
architecture of `agents-gvisor`:

```bash
git add container-images/agent-harness
git commit -m "fix(agent-harness): give agent-server time to export its root span"
git push
PR=$(gh pr view --json number --jq .number)
TAG="v0.1.2-pr${PR}.$(git rev-parse --short=8 HEAD)"
gh auth token | docker login ghcr.io -u Smana --password-stdin
docker build --platform linux/amd64 -t "ghcr.io/smana/agent-harness:${TAG}" container-images/agent-harness
docker push "ghcr.io/smana/agent-harness:${TAG}"
skopeo inspect --raw "docker://ghcr.io/smana/agent-harness:${TAG}" | sha256sum
```

If the push is denied, the gh token lacks `write:packages`, and [OWNER] runs the last four lines.

Then:
1. Pin `ghcr.io/smana/agent-harness:${TAG}@sha256:<digest>` in CC-O1's `_HARNESS_PROFILES.openhands.image`.
2. Re-run Task 1.5, Task 2.1 Step 3 and Tasks 3.1–3.3.
3. Propose SP2's H-S3 base edit (Cross-plan edits).

### Task 3.7: Evidence, and O-1 out of draft

- [ ] **Step 1:** Fill O-1's "Live evidence" from runbook 08's Results, dated.
- [ ] **Step 2:** Commit runbook 08's Results on O-1.
  - `docs(runbooks): per-run view results from the <date> rebuild`.
- [ ] **Step 3:** Record in the PR bodies which Δ the live run confirmed or added (Δ8 if Task 0.1's
  fallback fired).
- [ ] **Step 4:** Take O-1 and CC-O1 out of draft for review.
  - Both stay open until the programme's merge wave (P33), in the order the PR map gives.

---

## Further review (2026-09-29)

The owner accepted three additions from a further external review. SP3's share is in its own
"Further review (2026-09-29)" table.

| # | Addition | Where | What |
|---|---|---|---|
| F1 | A trigger-rooted trace per task | Task 0.5; Tasks 1.3a, 2.2a, 2.8a, 3.3a; O20, O21; Δ9; SP3 R46 | The composition projects `agents.ogenki.io/traceparent` as `TRACEPARENT`. The harness's `agent-run` span parents on it, or starts a fresh trace, and agent-server's root span joins it through `LMNR_SPAN_CONTEXT`. The collector's :4317 takes the factory's task spans. The harness closes the conversation before the stop, so the root span survives (was O13) |
| F2 | The step log carries `trace_id` | Tasks 2.6a, 2.8a, 3.3a; O22; Δ10 | Step lines end with `\| trace_id=<hex>`, and the run page turns it into a "View Trace" link through the existing `log.trace_id` derived field. Correlation only: attribution stays on `x_ar_agent` and the connection-stamped `agent.run_id` |
| F3 | Routing tier vs spend | Tasks 2.5a, 2.6a, 2.7a; O23, O24; SP3 R47 | `agentrun_info{tier}` from the claim label `agents.ogenki.io/tier`. The fleet page compares tier with tokens and steps per run, and tokens by tier; the run page shows the tier. One tier per run, never re-routed within it |

## GCP parity cross-plan edits (2026-09-29)

Applied from the GCP parity plan's [Cross-plan edits](2026-09-29-gcp-parity-plan.md#cross-plan-edits) (Observability share).

| ID | Where | What |
|---|---|---|
| O12 | Ruling O12; PR map's O-1 row | O-1's *Base* is `feat/gcp-agent-platform` (GCP parity G-5), itself on SP2's H-1 — was `fix/agent-review-hardening` directly |
| — | Owner action 3.1; Phase 0 intro; Phase 3 heading and intro | gcp-0, after GCP parity Task 8.6 — was "the next aws-0 rebuild" |
| — | Global Constraints (new bullet) | Every child O-1 adds to `clusters/aws-0-agent-platform/` gets its `clusters/gcp-0-agent-platform/` twin, `gke-gcp-0-vars` and a `*/gcp-0/*` overlay when it substitutes |
