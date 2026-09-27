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

### Step 4 — `internal` adds real read tools, gated by role

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/list | grep -o '"name":"[^"]*"'
```

Expected (the probe is an `implementer`): Flux's `search_flux_docs`, `get_flux_instance`,
`get_kubernetes_api_versions`, `get_kubernetes_resources`, `get_kubernetes_metrics` — **no** `get_kubernetes_logs`; plus every
`mcp-victoriametrics` tool; plus only `mcp-victorialogs`'s
`documentation` tool (not `query`, `hits`, etc.). Reviewer/tester/triager roles get
`get_kubernetes_logs` and the full VictoriaLogs tool set too — this probe only carries an
`implementer` identity, matching a real implementer run.

### Step 5 — SC-12: an implementer is denied the logs tool by the MCPRoute, and the backend SA has no secrets access

```bash
kubectl exec -n agents agent-probe -c probe -- sh /tmp/mcp.sh internal tools/call '{"name":"get_kubernetes_logs","arguments":{"name":"octo-sts","namespace":"agent-system"}}'
kubectl auth can-i get secrets --as=system:serviceaccount:agent-system:flux-operator-mcp -A
kubectl auth can-i get pods/log --as=system:serviceaccount:agent-system:flux-operator-mcp -A
```

Expected: the call is refused (HTTP 403, or a JSON-RPC error naming authorization — the MCPRoute's
`defaultAction: Deny` plus per-role rules never grant `implementer` this tool on `internal`); `no`;
`yes` (the `agent-mcp-flux-read` ClusterRole grants `pods/log` but no `secrets` verb at all, so even a
role the MCPRoute *does* authorize for this tool could never reach a Kubernetes Secret through it).

**What this proves:** SC-12 — an implementer calling `get_kubernetes_logs` is denied at the MCPRoute
layer, and the backend's own RBAC is a second, independent floor: `auth can-i get secrets` fails for
every role, not just implementer.

**What Step 3–4 together prove:** SC-17 (MCP half) — cluster-read tools (metrics, resources, logs)
are `internal`-only; `public` sees documentation tools regardless of role.

### Cleanup

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — routes accepted | `Ready=True`, both `True` | `agent-mcp` Ready=False (`dependency 'flux-system/agent-router' is not ready`); no MCPRoute objects exist yet at all | BLOCKED (owner action 1) |
| 2 — SC-08 recheck | No `kubernetes.io` dir | `ls: cannot access '/var/run/secrets/kubernetes.io': No such file or directory`, exit=2 | PASS |
| 3 — `public` tools | Exactly 3 docs tools | Not reachable — no MCPRoute/backends deployed | BLOCKED (owner action 1) |
| 4 — `internal` tools | Implementer: no logs tool; full VM set; VL docs only | Not reachable, same cause. Statically verified in `infrastructure/base/agent-mcp/mcproutes.yaml`: implementer's `agent-router.implementer.internal` rules grant exactly `search_flux_docs`, `get_flux_instance`, `get_kubernetes_api_versions`, `get_kubernetes_resources`, `get_kubernetes_metrics` (no `get_kubernetes_logs`), the full `mcp-victoriametrics` tool list, and only `mcp-victorialogs`'s `documentation`; `reviewer` additionally gets `get_kubernetes_logs` | BLOCKED (owner action 1) — static match confirmed |
| 5 — SC-12 denial | Refused | Not reachable, same cause | BLOCKED (owner action 1) |
| 5 — RBAC | `no` (secrets), `yes` (pods/log) | ClusterRole `agent-mcp-flux-read` does not exist yet (never applied): `can-i get secrets` → `no`, `can-i get pods/log` → `no` (not `yes` — the resource itself is missing, not merely denying `pods/log`). Statically verified in `infrastructure/base/agent-mcp/flux-operator-mcp-rbac.yaml`: no `secrets` verb anywhere; `pods/log` is granted `get,list,watch` once the Kustomization reconciles | BLOCKED (owner action 1) — static match confirmed |
