# 08 — Observability

Proves that the agent-platform VMRules load and their expressions evaluate against real data, that
the Grafana dashboard renders with live panels, that SP4's gateway metrics (`ar_agent`,
`ar_client`) are queryable end to end, and (Steps 6–10) the per-run view. This is a light confirmation pass, best run after — or
alongside — runbooks 01–07, since it needs live runs to have produced some signal. See
[README.md](README.md) for prerequisites; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done, and `CLOUD` set (README).
- At least one run from an earlier runbook executed recently, so the metrics and log queries below
  have something to show — an empty result is not the same as a broken rule.

## Steps

### Step 1 — the VMRules loaded

```bash
kubectl get vmrule -n observability agent-platform agent-platform-logs agent-factory agent-rooms -o custom-columns=NAME:.metadata.name,GROUPS:'.spec.groups[*].name'
```

Expected: four objects, each listing the group of its own name (`agent-platform`,
`agent-platform-logs`, `agent-factory`, `agent-rooms`). The logs group carries `type: vlogs` and is
skipped (visibly, not silently) by `promtool`-based validation — its evidence is querying the
expression directly, which the next two steps do.

### Step 2 — the pod-pending alert expression evaluates, and the gVisor pool has room

```bash
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=max%20by%20(pod)%20(kube_pod_status_phase%7Bnamespace%3D%22agents%22%2C%20phase%3D%22Pending%22%7D)" | jq '.data.result'
LABEL=sandbox.gke.io/runtime=gvisor; [ "$CLOUD" = aws ] && LABEL=agents.ogenki.io/runtime=gvisor
kubectl get nodes -l "$LABEL" --no-headers | wc -l
if [ "$CLOUD" = gcp ]; then
  gcloud container node-pools describe agents-gvisor --cluster gcp-0 --location europe-west4-a \
    --project ogenki-435905 --format='value(autoscaling.maxNodeCount)'
else
  kubectl get nodepool agents-gvisor -o jsonpath='{.spec.limits}{"\n"}'
fi
```

Expected: the first query returns `success` (`[]` when no pod is Pending is a pass, not a FAIL);
`≥ 1` gVisor node while a run is live (on gcp-0, node auto-provisioning may add
`nap-e2-standard-4-*` gVisor nodes besides the pool's); the pool's max, `2` nodes on gcp-0 or
`{"cpu":"16","memory":"64Gi"}` on aws-0.

**What this proves:** `AgentSandboxPodPending` is wired to a real metric name (`kube_pod_status_phase`)
on this cluster, and the `agents-gvisor` pool (`opentofu/gcp/gke/init/sandbox.tf` on gcp-0) has room
to scale.
**`AgentGvisorPoolNearLimit` never fires on gcp-0.** Per `observability/base/agent-platform/vmrule.yaml`,
that alert reads `karpenter_nodepools_usage`/`karpenter_nodepools_limit` — Karpenter-only metrics
that have no series here, because gcp-0's `agents-gvisor` pool is a GKE node pool, not a Karpenter
NodePool. On aws-0 the same alert is the pool's real near-limit signal. On gcp-0 a full pool instead
surfaces as `AgentSandboxPodPending` — the check above is the direct substitute.

### Step 3 — the two log-based alert expressions evaluate

The expressions are the rules' own, from `observability/base/agent-platform/vmrule-logs.yaml`,
prefixed with the rules' 5-minute window.

```bash
curl -sS --cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem https://vl.priv.$CLOUD.ogenki.io/select/logsql/query --data-urlencode \
  'query=_time:5m kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" AND kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-namespace:"agent-system" | unpack_json | log.response_code:~"(401|403)" | stats count() as rejected | filter rejected:>20'
curl -sS --cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem https://vl.priv.$CLOUD.ogenki.io/select/logsql/query --data-urlencode \
  'query=_time:5m kubernetes.pod_labels.app.kubernetes.io/name:"octo-sts" AND _msg:~"(?i)(error|denied|failed)" | stats count() as failures | filter failures:>5'
```

Expected: both queries run without a syntax error (an empty result means the 5-minute window has
fewer than the threshold — that's a pass, not a failure of the rule).

**What this proves:** `AgentRouterUnauthorizedBurst` and `OctoStsExchangeFailures` are valid LogsQL
against this cluster's actual log fields.

### Step 4 — the dashboard renders

Open Grafana at `https://grafana.priv.$CLOUD.ogenki.io`, folder **agents**,
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
| agents-gvisor usage / limit | `karpenter_nodepools_usage / karpenter_nodepools_limit` for `agents-gvisor` | Empty on gcp-0: Karpenter-only metric, no series on a GKE node pool. Non-empty on aws-0, may be near-zero if the pool scaled to zero |
| agent-router 4xx | LogsQL, `log.response_code:4*` | Entries corresponding to the 401/403 checks in runbooks 02 and 04 |

The "Tokens per run" panel is empty only if no run made model calls in the window. Record "no data"
as a fail only if a run from an earlier runbook definitely made model calls in the last 24h.

### Step 5 — SP4's gateway metrics, independent of the dashboard

```bash
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=sum%20by%20(ar_client)%20(gen_ai_client_token_usage_sum)" | jq '.data.result'
```

Expected: a `promptfoo` (or other API-key client) series if runbook 04 ran in this session, and/or
`system:serviceaccount:agents:...` series if any SP1 run made model calls — `ar_agent` and `ar_client`
are two different label values on the same underlying metric, one for agents, one for human/system
clients through `apiKeyAuth`.

## Per-run view (agent observability)

Proves SO-1…SO-5 of `docs/superpowers/specs/2026-09-27-agent-observability-design.md`. Two runs are
started here: A plants three markers that must never reach VictoriaTraces, and B stays up for the
network checks. Run from the repository root.

```bash
CLOUD=gcp                                     # or aws
CA=opentofu/$CLOUD/openbao/management/.tls/ca.pem
VT=https://vt.priv.$CLOUD.ogenki.io
VL=https://vl.priv.$CLOUD.ogenki.io
VM="/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query"
vmq() { kubectl get --raw "$VM?query=$(jq -rn --arg q "$1" '$q|@uri')" | jq -c '.data.result'; }
OUT=$(mktemp -d)
R=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
```

`$CA` is the private CA every curl below needs (README).

### Step 6 — the platform pieces are up

```bash
kubectl get deploy -n observability agent-traces-collector -o jsonpath='{.status.readyReplicas}'; echo
kubectl logs -n observability deploy/agent-traces-collector | grep -ciE 'forbidden|cannot list'
POD=$(kubectl get pod -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=agent-router -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system "pod/$POD" 19000:19000 >/dev/null & PF=$!; sleep 2
curl -s localhost:19000/config_dump | grep -c 'envoy.tracers.opentelemetry'; kill $PF
```

Expected: `1`; `0`; a positive count.

A `forbidden` line means the collector's Role is too narrow for `k8s_attributes`. Record it, and widen
the Role to the chart preset's `pods` and `namespaces` `get/list/watch`, as a ClusterRole.

**What this proves:** the collector runs on its namespaced Role, and agent-router carries the
OpenTelemetry tracer.

### Step 7 — SO-5, and the two runs

```bash
task agent:run -- --role implementer --class public --task "Run \`echo TMARK-$R\` in the terminal. Then finish; your final message is exactly CMARK-$R. Never repeat this token: PMARK-$R." 2>$OUT/err | tail -1 | tee $OUT/a
grep '^agent-run: dashboard ' $OUT/err
task agent:run -- --role implementer --class public --task "Run \`sleep 240; ls docs\` in the terminal, then finish." 2>/dev/null | tail -1 | tee $OUT/b
A=$(sed 's/^xplane-run-//' $OUT/a); B=$(sed 's/^xplane-run-//' $OUT/b)
sleep 60; vmq "agentrun_status_phase{run_id=\"$A\"} == 1"
```

Expected:
- `tail -1` prints `xplane-run-<8 chars>` twice.
- `$OUT/err` holds `agent-run: dashboard https://grafana.priv.$CLOUD.ogenki.io/d/agent-run/agent-run?var-run=<A>&from=<13 digits>&to=now`.
- The query returns one series, whose `phase` is `Pending` or `Running`.

**What this proves:** SO-5, the run's page link on stderr. It also proves that kube-state-metrics
exports `AgentRun` state.

### Step 8 — SO-3: one trace, a span per model call, no content

Once A has ended:

```bash
kubectl wait agentrun/xplane-run-$A -n agents --for=jsonpath='{.status.phase}'=Succeeded --timeout=20m
now=$(date +%s); tags=$(jq -rn --arg r "$A" '{"agent.run_id":$r}|tojson|@uri')
curl -s --cacert $CA "$VT/select/jaeger/api/traces?service=agent-harness&tags=$tags&limit=200&start=$(( (now-7200)*1000000 ))&end=$(( now*1000000 ))" > $OUT/traces.json
jq '[.data[].traceID] | unique | length' $OUT/traces.json
jq '[.data[].spans[] | select(.operationName | startswith("llm."))] | length' $OUT/traces.json
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$A\" AND log.path:~\"chat/completions\" AND log.response_code:\"200\" | stats count() calls"
for m in PMARK TMARK CMARK; do printf '%s %s\n' $m "$(curl -s --cacert $CA "$VT/select/logsql/query" --data-urlencode "query=_time:2h \"$m-$R\"" | wc -l)"; done
curl -s --cacert $CA "$VT/select/logsql/query" --data-urlencode "query=_time:2h \"span_attr:agent.run_id\":\"$A\" \"span_attr:redaction.redacted.count\":>0 | stats count() spans"
curl -s --cacert $CA "$VT/select/logsql/field_names" --data-urlencode "query=_time:2h \"span_attr:agent.run_id\":\"$A\"" | jq -r '.values[].value' | grep 'attr:' | sed -E 's/^.*attr://' | sort -u > $OUT/keys
python3 -c 'import sys,yaml; hr=next(d for d in yaml.safe_load_all(open("observability/base/agent-platform/agent-traces-collector.yaml")) if d and d["kind"]=="HelmRelease"); ok=set(hr["spec"]["values"]["alternateConfig"]["processors"]["redaction"]["allowed_keys"])|{"redaction.redacted.count","redaction.masked.count"}; print("outside the allowlist:", sorted(set(open(sys.argv[1]).read().split())-ok) or "none")' $OUT/keys
curl -s --cacert $CA "$VT/select/jaeger/api/traces?service=agent-router&tags=$(jq -rn --arg p "system:serviceaccount:agents:xplane-run-$A" '{"agent.principal":$p}|tojson|@uri')&limit=200&start=$(( (now-7200)*1000000 ))&end=$(( now*1000000 ))" | jq '[.data[].traceID] | unique'
```

Then the trace root, and the step log's trace link:

```bash
jq -r '.data[].spans[] | select((.references // []) | length == 0) | .operationName' $OUT/traces.json
jq -r '[.data[].spans[] | {id: .spanID, name: .operationName}] as $s | .data[].spans[] | select(.operationName == "conversation") | .references[0].spanID as $p | $s[] | select(.id == $p) | .name' $OUT/traces.json
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_name:\"xplane-run-$A\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run step \" | extract_regexp \"trace_id=(?P<trace_id>[0-9a-f]{32})\" | stats by (trace_id) count() lines"
jq -r '[.data[].traceID] | unique[]' $OUT/traces.json
```

Expected, in order:

| Check | Expected | If not |
|---|---|---|
| Traces for A | `1` | More than one: record it. The run page still lists every trace carrying A's `agent.run_id`, since it searches by tag |
| `llm.*` spans | Equal to `calls` | |
| `calls` | The run's model calls, > 0 | |
| Markers | `PMARK 0`, `TMARK 0`, `CMARK 0` | Content leaked: SO-3 fails |
| Redacted spans | > 0 | Zero markers prove nothing if no content was ever sent |
| Attribute keys | `outside the allowlist: none` | |
| Router trace ids | Equal to the harness trace's id | Other ids: no join. The run page still finds the router's spans, because it also looks them up by `agent.principal`. Known issue (F16, round 9): each `/mcp` call opens its own root trace today, so expect the harness trace id among the ids plus one per MCP call |
| Root spans | `agent-run` | |
| `conversation`'s parent | `agent-run` | No `conversation` span at all: raise the harness's `FLUSH_WAIT_S` |
| Step-log `trace_id` | One row, equal to the trace id, `lines` equal to the run's step count | |

**What this proves:** SO-3. A run is one trace, rooted at the harness's `agent-run` span, with a span
per model call. No prompt, tool or completion text reaches VictoriaTraces. The step log names the
trace, which is how the run's page links to it.

### Step 9 — SO-4: the collector's traces path only

While B is `Running`:

```bash
COLL=$(kubectl get svc -n observability agent-traces-collector -o jsonpath='{.spec.clusterIP}')
VTIP=$(kubectl get endpointslices -n observability -l kubernetes.io/service-name=victoria-traces-vt-single-server -o jsonpath='{.items[0].endpoints[0].addresses[0]}')  # headless Service: no clusterIP
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
kubectl logs -n observability deploy/agent-traces-collector | grep -ciE 'unmarshal|bad request|unsupported'
```

Expected:
- `traces 200`, `logs 403` (Cilium's L7 "Access denied"), `grpc blocked`, and a timeout name for
  `victoriatraces` (`URLError` or `TimeoutError`).
- Hubble shows `http-request FORWARDED (HTTP/1.1 POST …/v1/traces)`, `http-request DROPPED (HTTP/1.1
  POST …/v1/logs)`, and `Policy denied DROPPED` to :4317 and to :10428.
- The collector log count is `0`.

Look at the Hubble output for `/v1/logs` flows from a run's own harness, besides the probe's. A
`DROPPED` there means lmnr exports OTel log records. The CNP stops them, as the run CNP intends
(traces only, ADR-0051): record it.

If `traces` is `403` or times out, or Step 8 found no spans at all:
1. Run `kubectl logs -n observability deploy/agent-traces-collector | grep -i 'pod_association\|no pod'`.
2. Check Hubble's source IP for the flow.
3. If the source is the node rather than the pod, the collector cannot resolve the run: drop the L7
   `rules.http` from the run CNP's rule to :4318 and keep the L4 rule (a crossplane-configuration
   change). The path restriction then rests on the collector, which serves only `/v1/traces`.

**What this proves:** SO-4. A run can reach only the collector's OTLP/HTTP traces path, never logs,
never gRPC, and never VictoriaTraces directly.

### Step 10 — SO-1, SO-2, and the printer columns

```bash
kubectl annotate --overwrite agentrun -n agents xplane-run-$A agents.ogenki.io/pull-request=https://github.com/Smana/cloud-native-ref/pull/<a real PR number in this repo>
kubectl get agentrun -n agents
kubectl get agentrun -n agents xplane-run-$A -o jsonpath='{.metadata.annotations.agents\.ogenki\.io/usage-tokens} {.status.usage.tokens}{"\n"}'
vmq "topk by (run_id) (1, tlast_over_time(agentrun_pull_request_info{run_id=\"$A\"}[1h]))"
vmq "sum(max_over_time(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:xplane-run-$A\", gen_ai_token_type=~\"input|output\"}[2h]))"
vmq "max(agentrun_budget_max_tokens{run_id=\"$A\"})"
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_namespace:\"agents\" AND kubernetes.pod_name:\"xplane-run-$A\" AND kubernetes.container_name:\"harness\" AND _msg:~\"^agent-run\"" | jq -r '."kubernetes.pod_name"' | sort | uniq -c
curl -s --cacert $CA $VL/select/logsql/query --data-urlencode "query=_time:2h kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:xplane-run-$A\"" | jq -r '."log.x_ar_agent"' | sort | uniq -c
```

Expected:
- The header row reads `NAME ROLE CLASS PHASE BRANCH PRINCIPAL PR TOKENS REASON`. A's row shows the PR
  URL, and a TOKENS value equal to the two numbers the jsonpath prints. Those are the run meter's own
  reading (the annotation) and its projection (`status.usage.tokens`), equal and > 0. Never overwrite
  `usage-tokens` here: the composition never lowers `status.usage.tokens`, so a smaller value is
  ignored and a larger one destroys the real reading.
- `agentrun_pull_request_info` carries the `pull_request` label (a successful run emits it since
  60e02d9a).
- Gateway tokens are > 0, and the budget is `2000000`.
- Each `uniq -c` output has exactly one line: A's pod, then A's principal. B ran at the same time
  (SO-2).

[OWNER]:
1. Open **Agent fleet** at `https://grafana.priv.$CLOUD.ogenki.io` and click A's `run_id`.
2. Check that **Agent run** shows:
   - the phase `Succeeded`, and the reason (empty for a success)
   - the PR link (absent in round 9 from F18, fixed in 60e02d9a; not yet re-checked live)
   - gateway tokens against `maxTokens` 2000000
   - the step log, with the `TMARK` command
   - the trace table, and a trace view whose `llm.*` spans carry token counts
   - a step line with "View Trace", which opens A's trace
3. Record it under Results.

Tear down: `kubectl delete agentrun -n agents xplane-run-$A xplane-run-$B; rm -r $OUT`.

**What this proves:** SO-1 and SO-2. One run's page shows its outcome, spend, log and trace, and
nothing from a run beside it.

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — VMRules loaded | Both present, correct groups | `agent-platform`→`agent-platform`; `agent-platform-logs`→`agent-platform-logs` | PASS |
| 2 — pending expression, pool room | `success`; `1` while a run is live; max `2` | `AgentSandboxPodPending` expression `success`, `[]`. The gVisor node count was `0` when checked, before any run of this round; `maxNodeCount` = `2`. While runs were live, the `agents-gvisor` pool scaled 0→1 and NAP added `nap-e2-standard-4-*` gVisor nodes when `agents-gvisor`'s `e2-standard-8` hit `GCE quota exceeded` (see `results-gcp-0-2026-09-30.md`, F3) | PASS |
| 3 — log expressions | Both run without syntax error | Both `HTTP:200`, empty (below threshold). They need `--cacert opentofu/gcp/openbao/management/.tls/ca.pem` | PASS |
| 4 — dashboard | All 4 panels render | Grafana `/api/health` `200`. Panel expressions: phases `success` (`Running=3` at check time); tokens per run `success`, 9 series; `karpenter_nodepools_*` empty on gcp-0, as documented; agent-router 4xx rows present in VictoriaLogs (runbook 02). The UI itself is SSO-gated, so the owner still has to look at the render | PASS (data); render [OWNER] |
| 5 — gateway metrics | `ar_client`/`ar_agent` series present | `ar_client=promptfoo` `3073`; `ar_agent` series for `agent-probe` and eight runs (e.g. `xplane-run-4iv2rpdq` `120136`, `xplane-run-zt7vyyi6` `171116`) | PASS |

### Round 9 — gcp-0, 2026-10-01 (`integration/agent-factory` @ `147819ff`)

Steps 6–10 only. Run A = `xplane-run-c24jukd3` (created by round 8, `Succeeded`); run B =
`xplane-run-o52jjke6` (`sleep 240; ls docs`).

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 6 — platform pieces | `1`; `0`; a positive count | `agent-traces-collector` readyReplicas `1`; `forbidden\|cannot list` → `0`; agent-router `config_dump \| grep -c envoy.tracers.opentelemetry` → `20` | PASS |
| 7 — SO-5, KSM | `xplane-run-<id>`; dashboard link on stderr; one `agentrun_status_phase` series | B: `agent-run: dashboard https://grafana.priv.gcp.ogenki.io/d/agent-run/agent-run?var-run=o52jjke6&from=1790845430000&to=now`; `tail -1` → `xplane-run-o52jjke6`; one series, `phase="Pending"` | PASS |
| 8 — SO-3 | One trace, no content, keys in the allowlist, router joined | Traces `1`; `llm.*` spans `2` = calls `2`; `PMARK 0`, `TMARK 0`, `CMARK 0`; redacted spans `11`; `outside the allowlist: none`. Root `agent-run`; `conversation`'s parent `agent-run`; step log: one `trace_id` row, `lines` `2`. Router: 7 trace ids, the harness trace `7aa86bbb…` among them with both `chat/completions` spans; the other 6 are `/mcp` calls, each its own trace | PASS (router join partial: F16) |
| 9 — SO-4 | `traces 200`, `logs 403`, `grpc blocked`, `victoriatraces` timeout | `traces 200`, `logs 403`, `grpc blocked`; VictoriaTraces at its pod IP → `URLError`, Hubble `EGRESS DENIED … Policy denied DROPPED` to :10428 and :4317; `/v1/traces` FORWARDED, `/v1/logs` DROPPED. The harness exported no OTel log records. The runbook's old `VTIP` read the headless Service's `clusterIP` (`None`), so the first probe failed on DNS (F17, fixed in cb5b020e) | PASS |
| 10 — printer columns | PR URL and TOKENS in A's row | Header as expected; A's row `PR https://github.com/Smana/cloud-native-ref/pull/2136  TOKENS 16259` (the meter's value; `usage-tokens` was not overwritten) | PASS |
| 10 — SO-1 outcome series | A's PR in the outcome series | `agentrun_outcome_info{run_id="c24jukd3"}` → `[]`: a successful run had no series | **FAIL** (F18; fixed in 60e02d9a by `agentrun_pull_request_info`, re-run pending) |
| 10 — tokens, budget | Tokens > 0; budget `2000000` | `max_over_time(gen_ai_client_token_usage_sum{…c24jukd3}[3h])`: input `16164`, output `95`; budget `2000000`. The old `increase(…)` query returned `0` (F17, fixed in cb5b020e) | PASS |
| 10 — SO-2 | One line each | Step log `4 xplane-run-c24jukd3`; router `21 system:serviceaccount:agents:xplane-run-c24jukd3`, with a concurrent run up | PASS |
| 8, 10 — run page, View Trace | [OWNER] | Not yet done | [OWNER] |

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — VMRules loaded | Both present, correct groups | `agent-platform`→`agent-platform`; `agent-platform-logs`→`agent-platform-logs` | PASS |
| 2 — metric expressions | Both `200`, valid `data.result` | `AgentSandboxPodPending` expr: `success`, one stale `Pending` series from a prior run; `AgentGvisorPoolNearLimit` expr: `success`, `[]` | PASS |
| 3 — log expressions | Both run without syntax error | Both `HTTP:200`, empty result (below threshold) | PASS |
| 4 — dashboard | All 4 panels render | Grafana reachable (`/api/health` OK); dashboard itself is SSO-gated (401 headless) — all 4 panel expressions independently verified valid via steps 2/3/5 and the extra `sum by (phase) (kube_pod_status_phase{namespace="agents"})` check (`success`, `[]`, no pod Pending at check time) | PASS (data); UI render not exercised headlessly |
| 5 — gateway metrics | `ar_client`/`ar_agent` series present | `success`, `[]` — no series yet (no run has made a model call tonight; `agent-router`/Z.ai key not up, per owner actions 1–2) | PASS (empty is expected, not a fail) |
