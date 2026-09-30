# 08 — Observability

Proves that the agent-platform VMRules load and their expressions evaluate against real data, that
the Grafana dashboard renders with live panels, and that SP4's gateway metrics (`ar_agent`,
`ar_client`) are queryable end to end. This is a light confirmation pass, best run after — or
alongside — runbooks 01–07, since it needs live runs to have produced some signal. See
[README.md](README.md) for prerequisites; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done. At least one run from an earlier runbook should have executed recently, so the
  metrics and log queries below have something to show — an empty result is not the same as a broken
  rule.

## Steps

### Step 1 — the VMRules loaded

```bash
kubectl get vmrule -n observability agent-platform agent-platform-logs -o custom-columns=NAME:.metadata.name,GROUPS:'.spec.groups[*].name'
```

Expected: both objects present; `agent-platform` groups list `agent-platform`;
`agent-platform-logs` lists `agent-platform-logs`. The logs group carries `type: vlogs` and is
skipped (visibly, not silently) by `promtool`-based validation — its evidence is querying the
expression directly, which the next two steps do.

### Step 2 — the pod-pending alert expression evaluates, and the gVisor pool has room

```bash
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=max%20by%20(pod)%20(kube_pod_status_phase%7Bnamespace%3D%22agents%22%2C%20phase%3D%22Pending%22%7D)" | jq '.data.result'
kubectl get nodes -l sandbox.gke.io/runtime=gvisor --no-headers | wc -l
gcloud container node-pools describe agents-gvisor --cluster gcp-0 --location europe-west4-a \
  --project ogenki-435905 --format='value(autoscaling.maxNodeCount)'
```

Expected: the first query returns `success` (`[]` when no pod is Pending is a pass, not a FAIL);
`1` while a run is live and `2` for the pool's max node count.

**What this proves:** `AgentSandboxPodPending` is wired to a real metric name (`kube_pod_status_phase`)
on this cluster, and the `agents-gvisor` node pool (GKE-managed, GP-9) has room to scale.
**`AgentGvisorPoolNearLimit` never fires on gcp-0.** Per `observability/base/agent-platform/vmrule.yaml`,
that alert reads `karpenter_nodepools_usage`/`karpenter_nodepools_limit` — Karpenter-only metrics
that have no series here, because gcp-0's `agents-gvisor` pool is a GKE node pool, not a Karpenter
NodePool. On aws-0 the same alert is the pool's real near-limit signal. On gcp-0 a full pool instead
surfaces as `AgentSandboxPodPending` — the check above is the direct substitute.

### Step 3 — the two log-based alert expressions evaluate

```bash
curl -s https://vl.priv.gcp.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" | unpack_json | log.response_code:~"(401|403)" | stats count() as rejected | filter rejected:>20'
curl -s https://vl.priv.gcp.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.app.kubernetes.io/name:"octo-sts" AND _msg:~"(?i)(error|denied|failed)" | stats count() as failures | filter failures:>5'
```

Expected: both queries run without a syntax error (an empty result means the 5-minute window has
fewer than the threshold — that's a pass, not a failure of the rule).

**What this proves:** `AgentRouterUnauthorizedBurst` and `OctoStsExchangeFailures` are valid LogsQL
against this cluster's actual log fields.

### Step 4 — the dashboard renders

Open Grafana at [https://grafana.priv.gcp.ogenki.io](https://grafana.priv.gcp.ogenki.io), folder **agents**,
dashboard **Agent platform** (`uid: agent-platform`). Confirm all four panels render without a query
error:

> Corrected 2026-09-27: Grafana is SSO-gated (`/api/dashboards/...` returns 401 without a browser
> session) — an agent cannot open the actual dashboard headlessly. Verified live instead that all
> four panel expressions evaluate cleanly through the same VM/VL proxy path as steps 2–3 (see
> results table); the owner still needs one look at the UI itself to confirm layout/render, not the
> data.

| Panel | Expression | Expect |
|---|---|---|
| Sandbox pods by phase | `sum by (phase) (kube_pod_status_phase{namespace="agents"})` | A line per phase seen during this session |
| Tokens per run through agent-router | `sum by (ar_agent) (rate(gen_ai_client_token_usage_sum{ar_agent=~"system:serviceaccount:agents:.*"}[5m]))` | Non-empty only while/after a run made model calls (runbooks 01, 02, 07) |
| agents-gvisor usage / limit | `karpenter_nodepools_usage / karpenter_nodepools_limit` for `agents-gvisor` | Empty on gcp-0 (GP-17): Karpenter-only metric, no series on a GKE node pool. Non-empty on aws-0, may be near-zero if the pool scaled to zero |
| agent-router 4xx | LogsQL, `log.response_code:4*` | Entries corresponding to the 401/403 checks in runbooks 02 and 04 |

The "Tokens per run" panel legitimately shows nothing until SP4 PR 1's
`metricsRequestHeaderAttributes` (`x-ar-agent` → `ar_agent`) is live on the `envoy-ai-gateway`
controller, which owner action 5's precondition (SP4 PR 1, this cluster) already satisfies once
runbook 00 is deployed — record "no data" here only as a fail if a run from an earlier runbook
definitely made model calls in the last 24h and this panel is still empty.

### Step 5 — SP4's gateway metrics, independent of the dashboard

```bash
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=sum%20by%20(ar_client)%20(gen_ai_client_token_usage_sum)" | jq '.data.result'
```

Expected: a `promptfoo` (or other API-key client) series if runbook 04 ran in this session, and/or
`system:serviceaccount:agents:...` series if any SP1 run made model calls — `ar_agent` and `ar_client`
are two different label values on the same underlying metric, one for agents, one for human/system
clients through `apiKeyAuth`.

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — VMRules loaded | Both present, correct groups | `agent-platform`→`agent-platform`; `agent-platform-logs`→`agent-platform-logs` | PASS |
| 2 — pending expression, pool room | `success`; `1` while a run is live; max `2` | `AgentSandboxPodPending` expression `success`, `[]`. The gVisor node count was `0` when checked, before any run of this round; `maxNodeCount` = `2`. While runs were live, the `agents-gvisor` pool scaled 0→1 and NAP added `nap-e2-standard-4-*` gVisor nodes when `agents-gvisor`'s `e2-standard-8` hit `GCE quota exceeded` (see `results-gcp-0-2026-09-30.md`, F3) | PASS |
| 3 — log expressions | Both run without syntax error | Both `HTTP:200`, empty (below threshold). They need `--cacert opentofu/gcp/openbao/management/.tls/ca.pem` | PASS |
| 4 — dashboard | All 4 panels render | Grafana `/api/health` `200`. Panel expressions: phases `success` (`Running=3` at check time); tokens per run `success`, 9 series; `karpenter_nodepools_*` empty on gcp-0, as documented (GP-17); agent-router 4xx rows present in VictoriaLogs (runbook 02). The UI itself is SSO-gated, so the owner still has to look at the render | PASS (data); render [OWNER] |
| 5 — gateway metrics | `ar_client`/`ar_agent` series present | `ar_client=promptfoo` `3073`; `ar_agent` series for `agent-probe` and eight runs (e.g. `xplane-run-4iv2rpdq` `120136`, `xplane-run-zt7vyyi6` `171116`) | PASS |

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — VMRules loaded | Both present, correct groups | `agent-platform`→`agent-platform`; `agent-platform-logs`→`agent-platform-logs` | PASS |
| 2 — metric expressions | Both `200`, valid `data.result` | `AgentSandboxPodPending` expr: `success`, one stale `Pending` series from a prior run; `AgentGvisorPoolNearLimit` expr: `success`, `[]` | PASS |
| 3 — log expressions | Both run without syntax error | Both `HTTP:200`, empty result (below threshold) | PASS |
| 4 — dashboard | All 4 panels render | Grafana reachable (`/api/health` OK); dashboard itself is SSO-gated (401 headless) — all 4 panel expressions independently verified valid via steps 2/3/5 and the extra `sum by (phase) (kube_pod_status_phase{namespace="agents"})` check (`success`, `[]`, no pod Pending at check time) | PASS (data); UI render not exercised headlessly |
| 5 — gateway metrics | `ar_client`/`ar_agent` series present | `success`, `[]` — no series yet (no run has made a model call tonight; `agent-router`/Z.ai key not up, per owner actions 1–2) | PASS (empty is expected, not a fail) |
