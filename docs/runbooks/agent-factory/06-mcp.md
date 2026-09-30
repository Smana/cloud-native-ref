# 06 — MCP tools

Proves that the two `MCPRoute`s (`public`, `internal`) expose exactly the tools each role/class
combination should see — `public` is documentation-only for every role, `internal` adds real
cluster-read tools but keeps logs off-limits to the implementer role — and that the backing
`flux-operator-mcp` ServiceAccount's own Kubernetes RBAC excludes secrets, independent of what the
MCPRoute authorization allows. See [README.md](README.md) for prerequisites; run
[00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done. No owner action.

## Steps

### Step 0 — the MCP session seed is the generated one (review M7)

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
flux get kustomizations -n flux-system agent-mcp
kubectl get mcproute -n agent-system -o custom-columns=NAME:.metadata.name,ACCEPTED:'.status.conditions[?(@.type=="Accepted")].status'
```

Expected: `Ready=True`; both MCPRoutes `True`. If one is not, read its condition message before
continuing.

### Step 2 — SC-08 (no API route from a run), quick recheck

```bash
RUN=$(task agent:run -- --role implementer --class public --task "Idle. Do nothing." --minutes 15 | tail -1)
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl exec -n agents $RUN -c harness -- ls /var/run/secrets/kubernetes.io ; echo "exit=$?"
kubectl delete agentrun -n agents $RUN --wait
```

Expected: `No such file or directory`, `exit=2` (already proven in runbook 01; kept here since it
gates whether the rest of this runbook's tool checks mean anything).

### Step 3 — SC-17 (MCP half): `public` is documentation-only

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
kubectl cp scripts/ops/k8s/agent-probe-mcp.sh agents/agent-probe:/tmp/mcp.sh -c probe
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh public tools/list | grep -o '"name":"[^"]*"'
```

Expected: exactly three tool names — `search_flux_docs`, and one `documentation` tool from each of
`mcp-victoriametrics` and `mcp-victorialogs`. No `get_kubernetes_*`, no `query`, no mutating tool of
any kind.

> Corrected 2026-09-27: tool names are namespaced by backend, e.g.
> `flux-operator-mcp__search_flux_docs`, not the bare `search_flux_docs` — verified live. Match on
> the suffix.

### Step 4 — `internal` adds real read tools, gated by role

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/list | grep -o '"name":"[^"]*"'
```

Expected (the probe is an `implementer`): Flux's `search_flux_docs`,
`get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_metrics`: **no**
`get_kubernetes_logs` and **no** `get_kubernetes_resources`. Thirteen `mcp-victoriametrics` tools,
none of `tsdb_status`, `active_queries`, `top_queries`. Only `mcp-victorialogs`'s `documentation`.
Reviewer, tester and triager also get `get_kubernetes_resources`, `get_kubernetes_logs` and the
VictoriaLogs query tools.

### Step 5 — SC-12: an implementer is denied the logs tool by the MCPRoute, and the backend SA has no secrets access

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/call '{"name":"flux-operator-mcp__get_kubernetes_logs","arguments":{"name":"octo-sts","namespace":"agent-system"}}'
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -A
kubectl auth can-i get pods/log --as=system:serviceaccount:agent-system:flux-operator-mcp -n flux-system
kubectl auth can-i get pods/log --as=system:serviceaccount:agent-system:flux-operator-mcp -n security
kubectl auth can-i get configmaps --as=system:serviceaccount:agent-system:flux-operator-mcp -n security
kubectl auth can-i list nodes --as=system:serviceaccount:agent-system:flux-operator-mcp
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -n flux-system
```

> Corrected 2026-09-27: the tool name must be the namespaced form
> (`flux-operator-mcp__get_kubernetes_logs`, per Step 3's correction above) — the bare
> `get_kubernetes_logs` used previously here fails with a generic `400 invalid tool name` before
> authorization is ever evaluated, which looks like a pass but proves nothing about SC-12.

Expected: the call is refused (HTTP 403, or a JSON-RPC error naming authorization — the MCPRoute's
`defaultAction: Deny` plus per-role rules never grant `implementer` this tool on `internal`); `no`;
`yes` for `pods/log` in `flux-system`, `no` for `pods/log` in `security`, `no` for `configmaps` in
`security`, `no` for `list nodes` (cluster-scoped, no namespace), `no` for `secrets` in `flux-system`
too (the `flux-system` Role grants only `configmaps` and `pods/log`, in that namespace alone; the
cluster-wide `agent-mcp-flux-read` ClusterRole grants neither `pods/log` nor `configmaps` any more,
and never granted `secrets`).

**What this proves:** SC-12 — an implementer calling `get_kubernetes_logs` is denied at the MCPRoute
layer, and the backend's own RBAC is a second, independent, namespace-scoped floor: `pods/log` and
`configmaps` are readable only in `flux-system`, nowhere else, and `secrets` fails everywhere for
every role.

**What Step 3–4 together prove:** SC-17 (MCP half) — cluster-read tools (metrics, resources, logs)
are `internal`-only; `public` sees documentation tools regardless of role.

### Cleanup

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Results

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
