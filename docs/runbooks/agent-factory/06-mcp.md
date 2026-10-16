# 06 — MCP tools

Proves that agentgateway's MCP federation (one `AgentgatewayBackend`, `agent-mcp`, behind a route
and an `Allow` list per listener, `public` and `internal`, in `infrastructure/base/agent-gateway/mcp.yaml`)
exposes exactly the tools each role/class
combination should see — `public` carries no cluster-read tool for any role (documentation plus the
role's `room_*` tools), `internal` adds real cluster-read tools but keeps logs off-limits to the
implementer role — and that the backing
`flux-operator-mcp` ServiceAccount's own Kubernetes RBAC excludes secrets, independent of what the
gateway's `Allow` lists permit. See [README.md](README.md) for prerequisites; run
[00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done. No owner action.

## Steps

### Step 0 — the MCP session seed is the generated one

This guards the Envoy AI Gateway controller, which no longer serves any agent MCP traffic since phase H
(#2429); agentgateway federates with `sessionRouting: Stateless`. Keep it while that controller runs
`ai-gateway`.

```bash
kubectl get pods -n envoy-ai-gateway-system -l app.kubernetes.io/instance=envoy-ai-gateway,app.kubernetes.io/name=ai-gateway-helm -o json \
  | jq -r '[.items[].spec.containers[].args[]? | select(startswith("--mcpSessionEncryptionSeed="))
           | sub("^--mcpSessionEncryptionSeed="; "")
           | if . == "default-insecure-seed" then "INSECURE" elif length == 48 then "generated" else "length \(length)" end]
           | unique | join(",")'
```

Expected: `generated`, never the value itself. `INSECURE` means the HelmRelease's `valuesFrom`
(`ai-gateway-mcp-session-seed`, key `seed`) no longer reaches the chart: stop, every MCP session ID
is encrypted with a published seed. `length N` means the value is not the 48-character `Password`
generator's. An empty output means the flag moved: read the pod's args by hand.

### Step 1 — the routes are accepted

```bash
flux get kustomizations -n flux-system agent-mcp agent-gateway
kubectl get httproute -n agent-system agentgateway-mcp-public agentgateway-mcp-internal \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.parents[*].conditions[?(@.type=="Accepted")].status}{"\n"}{end}'
```

Expected: both Kustomizations `Ready=True`; both routes `True`. If one is not, read its condition message before
continuing.

### Step 2 — SC-08 (no API route from a run), quick recheck

```bash
RUN=$(task agent:run -- --role implementer --class public --task "Run 'sleep 300' in the terminal, then finish. Change nothing." | tail -1)
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl exec -n agents $RUN -c harness -- ls /var/run/secrets/kubernetes.io ; echo "exit=$?"
kubectl delete agentrun -n agents $RUN --wait
```

Expected: `No such file or directory`, `exit=2` (already proven in runbook 01; kept here since it
gates whether the rest of this runbook's tool checks mean anything).

### Step 3 — SC-17 (MCP half): `public` has no cluster-read tool

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
kubectl cp scripts/ops/k8s/agent-probe-mcp.sh agents/agent-probe:/tmp/mcp.sh -c probe
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh public tools/list | grep -o '"name":"[^"]*"'
```

Expected: exactly the three documentation tools `flux-operator-mcp_search_flux_docs`,
`mcp-victoriametrics_documentation` and `mcp-victorialogs_documentation`. No `get_kubernetes_*`, no
`query`, no other tool. agentgateway names every tool `<target>_<tool>` (`prefixMode: Always`), the
target being the server's name in `agent-mcp`.

No `room-broker_*` tool for the probe: the broker answers only a live run's `sub` (403 otherwise), and
`failureMode: FailOpen` drops a refusing target from the list. A real implementer run also sees
`room-broker_room_read`, `room-broker_room_post`, `room-broker_room_progress` and
`room-broker_room_handoff`. `scripts/ops/k8s/agentgateway-poc-checks.py` asserts the same set (L3).

### Step 4 — `internal` adds real read tools, gated by role

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/list | grep -o '"name":"[^"]*"'
```

Expected (the probe is an `implementer`):

| Backend | Implementer sees | Never |
|---|---|---|
| `flux-operator-mcp` | `search_flux_docs`, `get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_metrics` | `get_kubernetes_logs`, `get_kubernetes_resources` |
| `mcp-victoriametrics` | 13 tools | `tsdb_status`, `active_queries`, `top_queries` |
| `mcp-victorialogs` | `documentation` only | the query tools |
| `room-broker` | `room_read`, `room_post`, `room_progress`, `room_handoff` (a live run only, as in Step 3) | `room_verdict` |

Other roles, from `infrastructure/base/agent-gateway/mcp.yaml` (its Allow lists): reviewer, tester and triager also
get `get_kubernetes_resources`, `get_kubernetes_logs` and the VictoriaLogs query tools. Room tools:
reviewer `room_read`, `room_post`, `room_progress`, `room_verdict`; tester all five; triager `room_read`, `room_post`, `room_progress`,
`room_handoff`.

### Step 5 — SC-12: an implementer is denied the logs tool by the gateway, and the backend SA has no secrets access

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/call '{"name":"flux-operator-mcp_get_kubernetes_logs","arguments":{"name":"octo-sts","namespace":"agent-system"}}'
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal-reviewer tools/call '{"name":"flux-operator-mcp_get_kubernetes_logs","arguments":{"name":"octo-sts","namespace":"agent-system"}}'
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -A
kubectl auth can-i get pods --subresource=log --as=system:serviceaccount:agent-system:flux-operator-mcp -n flux-system
kubectl auth can-i get pods --subresource=log --as=system:serviceaccount:agent-system:flux-operator-mcp -n security
kubectl auth can-i get configmaps --as=system:serviceaccount:agent-system:flux-operator-mcp -n security
kubectl auth can-i list nodes --as=system:serviceaccount:agent-system:flux-operator-mcp
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -n flux-system
```

A denied call answers like a typo: agentgateway returns `Unknown tool`, not a permission error
(ADR-0053; agentgateway#3710). The second call is the control that tells them apart: the reviewer's
`Allow` list grants the same name, so its call must reach the server. `kubectl auth can-i get
pods/log` would check a pod *named* `log`; `--subresource=log` asks the real question.

Expected: the implementer's call is refused with `Unknown tool` (a JSON-RPC error or an `isError`
result; verify on next run: the exact reply is not yet recorded on the real Gateway). No
`matchExpressions` entry in `agentgateway-mcp-internal` grants `implementer` this tool. The reviewer's
call is not `Unknown tool`: it reaches `flux-operator-mcp`, whose RBAC then refuses `pods/log` in
`agent-system` (the floor below); `no`;
`yes` for `pods/log` in `flux-system`, `no` for `pods/log` in `security`, `no` for `configmaps` in
`security`, `no` for `list nodes` (cluster-scoped, no namespace), `no` for `secrets` in `flux-system`
too (the `flux-system` Role grants only `configmaps` and `pods/log`, in that namespace alone; the
cluster-wide `agent-mcp-flux-read` ClusterRole grants neither `pods/log` nor `configmaps` any more,
and never granted `secrets`).

**What this proves:** SC-12 — an implementer calling `get_kubernetes_logs` is denied at the gateway
layer, and the backend's own RBAC is a second, independent, namespace-scoped floor: `pods/log` and
`configmaps` are readable only in `flux-system`, nowhere else, and `secrets` fails everywhere for
every role.

**What Step 3–4 together prove:** SC-17 (MCP half) — cluster-read tools (metrics, resources, logs)
are `internal`-only; `public` sees documentation and room tools regardless of role.

### Cleanup

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Results

> Every round below predates phase H (#2429): it ran against Envoy's MCPRoutes, whose tool names
> read `<server>__<tool>` and whose denial was `access denied`, HTTP 403.

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 0 — MCP session seed | generated | `generated` | PASS |
| 1 — routes accepted | `Ready=True`, both `True` | `agent-mcp` `Ready=True`; `agent-mcp-internal` `True`, `agent-mcp-public` `True` | PASS |
| 2 — SC-08 recheck | No `kubernetes.io` dir | Run `xplane-run-6qnowwxl` (shared with runbooks 01, 03 and 05): `No such file or directory`, exit=2 | PASS |
| 3 — `public` tools | Exactly 3 docs tools | `flux-operator-mcp__search_flux_docs`, `mcp-victorialogs__documentation`, `mcp-victoriametrics__documentation` | PASS |
| 4 — `internal` tools | Implementer: 4 Flux tools, no logs/resources; 13 VM tools; VL docs only | Flux: `search_flux_docs`, `get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_metrics`. 13 `mcp-victoriametrics` tools, none of `tsdb_status`, `active_queries` or `top_queries`. Only `mcp-victorialogs__documentation` | PASS |
| 5 — SC-12 denial | Refused | `flux-operator-mcp__get_kubernetes_logs` → `access denied`, `HTTP 403` | PASS |
| 5 — RBAC | `no`, `yes`, `no`, `no`, `no`, `no` | `get secrets -A` `no`; `configmaps -n security` `no`; `list nodes` `no`; `get secrets -n flux-system` `no`. **The two `pods/log` lines as written answer the wrong question.** `kubectl auth can-i get pods/log` parses `log` as a pod *name*, so it answered `yes` in `security` through the cluster-wide `get pods`. With `--subresource=log`, the answers are `no` in `security` and `yes` in `flux-system`. A SubjectAccessReview agrees: `allowed:false` in `security`, `allowed:true` in `flux-system` "by RoleBinding agent-mcp-flux-read/flux-system". Use `kubectl auth can-i get pods --subresource=log …` | PASS (with the corrected command) | <!-- pragma: allowlist secret -->

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 0 — MCP session seed | generated | | |
| 1 — routes accepted | `Ready=True`, both `True` | `agent-mcp` `SUSPENDED=False READY=True`; both `agent-mcp-internal` and `agent-mcp-public` MCPRoutes `Accepted=True` | PASS |
| 2 — SC-08 recheck | No `kubernetes.io` dir | Run `xplane-run-n6uymuev`: `ls: cannot access '/var/run/secrets/kubernetes.io': No such file or directory`, exit=2 | PASS |
| 3 — `public` tools | Exactly 3 docs tools | `flux-operator-mcp__search_flux_docs`, `mcp-victoriametrics__documentation`, `mcp-victorialogs__documentation` — exactly 3, no `get_kubernetes_*`, no `query` | PASS |
| 4 — `internal` tools | Implementer: no logs tool; full VM set; VL docs only | 5 flux tools (`search_flux_docs`, `get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_resources`, `get_kubernetes_metrics`, no `get_kubernetes_logs`); all 13 `mcp-victoriametrics` tools; only `mcp-victorialogs__documentation` | PASS |
| 5 — SC-12 denial | Refused | `flux-operator-mcp__get_kubernetes_logs` call → `access denied`, HTTP 403 (the bare, unprefixed name instead fails with a generic 400 before authz runs — see correction above) | PASS |
| 5 — RBAC | `no` (secrets), `yes` (pods/log) | `can-i get secrets --as=...flux-operator-mcp -A` → `no`; `can-i get pods/log` → `yes` | PASS | <!-- pragma: allowlist secret -->
