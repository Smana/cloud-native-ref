# 04 — Gateway, secrets and budgets

Two independent gateways are in scope here. **Part A (SP1)** proves that no provider key ever lands
in namespace `agents`, and that the `agents-secrets` OpenBao role reads the `agents` mount and
nothing else — plus the `internal`-listener half of SC-17 (an `internal` run has no route to Z.ai
at all). **Part B (SP4 PR 1)** proves the human/system Gateway's frontier route answers real chat
requests, its token usage is counted (in shadow mode, nothing is rejected on the real route), and a
route-level rate-limit policy actually fires a 429 when its bucket is exhausted — the mechanism
SP4's real budgets (still shadow-only) will use once enforcement ships. See [README.md](README.md)
for prerequisites; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00 done.
- **Owner action 2**: the agents' dedicated Z.ai key written to `agents/zai` — without it, Part A's
  `ExternalSecret` stays un-synced (harmless for this runbook's assertions, which are about denial and
  scope, but note it in the results table if it's missing).
- Part B needs the promptfoo API key from the `ai-gateway-promptfoo-key` Password generator (Step
  B.1). gcp-0 generates its gateway client keys in-cluster, so no AWS credentials are needed.

## Part A — `agents-secrets` scope (SC-10) and the internal listener (SC-17, listener half)

### Step 1 — confirm the store synced

```bash
flux get kustomizations -n flux-system | grep -E '^(agent-secrets|agent-router)[[:space:]]'
kubectl get secretstore -n agent-system agents-secrets -o jsonpath='{.status.conditions[0].status}{"\n"}'
kubectl get externalsecret -n agent-system agents-zai-api-key -o jsonpath='{.status.conditions[0].reason}{"\n"}'
```

> Corrected 2026-09-27: `flux get kustomization` only reads the first positional name; list-then-grep.

Expected: both `Ready=True`; `True`; `SecretSynced` (needs owner action 2).

### Step 2 — the gateway-name label exists (both data-plane CNPs depend on it)

The risk checked here: the CNPs select Envoy Gateway's proxy pods by a label Envoy Gateway sets, not
one this repo controls.

```bash
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=agent-router,gateway.envoyproxy.io/owning-gateway-namespace=agent-system -o name
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=ai-gateway -o name
```

Expected: two `agent-router` pods (2 replicas) and one `ai-gateway` pod. If either is empty, **stop** — the data-plane CNP for that Gateway selects
no proxy pod, Cilium then allows everything on the unselected side, and every 401/403 check in this
session is meaningless until it's fixed.

### Step 3 — SC-10: no key in `agents`, and the store's reach

> Note: the OpenBao capability probe (`bao write auth/jwt/$CLOUD-0/login ...`) mints a live OpenBao
> token via a `bao write` call. This session's rules forbid any write to OpenBao, so this half of
> the step is not run here — the owner must run it (see the Results table).

```bash
kubectl get secrets -n agents -o name | grep -vx secret/room-broker-ca | wc -l
kubectl apply --dry-run=server -f - <<'YAML'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: sc10, namespace: agents}
spec:
  secretStoreRef: {kind: ClusterSecretStore, name: openbao-platform}
  target: {name: sc10}
  data: [{secretKey: k, remoteRef: {key: llm/zai, property: api_key}}]
YAML
export VAULT_ADDR=https://bao.priv.$CLOUD.ogenki.io:8200 VAULT_CACERT=opentofu/$CLOUD/openbao/management/.tls/ca.pem
JWT=$(kubectl create token agents-secrets -n agent-system --audience openbao --duration 10m)
T=$(bao write -field=token auth/jwt/$CLOUD-0/login role=agents-secrets jwt="$JWT")
bao token capabilities "$T" agents/data/zai
bao token capabilities "$T" platform/data/agents/zai
bao token capabilities "$T" platform/data/llm/zai
bao token capabilities "$T" apps/data/anything
bao token revoke "$T"
```

Expected: `0` secrets in `agents` besides `room-broker-ca`; the `ExternalSecret` denied by
`agents-no-secret-import` (`namespace agents holds no secret: External Secrets objects are refused,
but for the room-broker-ca certificate`); `read`, `deny`, `deny`, `deny`.

**What this proves:** SC-10 — namespace `agents` holds no Secret but the room broker's CA
certificate (the one ExternalSecret the policy admits by name), cannot import another, and the
namespaced `agents-secrets` OpenBao role is scoped to exactly `agents/*` (never the old
`platform/agents/*` path, never `platform/llm/*`, never any other mount).

### Step 4 — SC-17, listener half: `internal` cannot reach Z.ai

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
# The token substitution ($(cat ...)) runs INSIDE the pod's shell, so it never
# appears in this host's process list or shell history.
kubectl exec -n agents agent-probe -c probe -- sh -c "curl -s -o /dev/null -w 'internal chat %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/internal/token)\" -H 'content-type: application/json' -d '{\"model\":\"agent-default\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' http://agent-router.envoy-gateway-system.svc.cluster.local:8081/v1/chat/completions"
curl -sS --cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem https://vl.priv.$CLOUD.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" _time:15m | unpack_json | log.listener_port:8081 | stats by (log.upstream_cluster) count() hits'
```

Expected: `internal chat 404` — SP1 seeds only the `public`-listener Z.ai route
(`agent-models`); `internal` is meant for Bedrock EU and self-hosted backends only, from SP4 PR 2,
not yet built. No `upstream_cluster` containing `zai` among the 8081 lines.

**What this proves:** SC-17 (listener half) — an `internal`-class run has no path to Z.ai whatsoever,
structurally (the route doesn't exist on that listener), not just by audience mismatch.

### Cleanup

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Part B — SP4 frontier route and budgets (200, then 429)

### Step 1 — get the promptfoo API key

```bash
LLM_API_KEY=$(kubectl get secret -n envoy-ai-gateway-system ai-gateway-api-keys -o jsonpath='{.data.promptfoo}' | base64 -d)
```

The Secret holds the keys `openwebui` and `promptfoo`. On gcp-0 the value comes from the
`ai-gateway-promptfoo-key` Password generator (`CreatedOnce`). Never echo `$LLM_API_KEY`.

An agent session's permission classifier may refuse this command (credential materialization). Steps
3–6 then need the owner's session; Step 2 does not need the key.

### Step 2 — check the budget policy and the rate-limit store are live

```bash
kubectl get kvstore -n envoy-gateway-system xplane-ai-gateway-ratelimit
kubectl get pods -n envoy-gateway-system -l app.kubernetes.io/name=envoy-ratelimit
kubectl get btp -n envoy-ai-gateway-system ai-gateway-token-budgets \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {.reason}{"\n"}{end}'
```

Expected: `READY True`; `Running 1/1`; `Accepted=True` (never `Conflicted` or `Invalid`).

### Step 3 — call the frontier route

```bash
curl -sS --cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem https://llm.priv.$CLOUD.ogenki.io/v1/chat/completions -H "Authorization: Bearer $LLM_API_KEY" \
  -H "Content-Type: application/json" -H "x-ai-gateway-client-id: forged" \
  -d '{"model":"tier-frontier","messages":[{"role":"user","content":"Reply with the word ok"}]}' | jq '.model, .usage'
```

Expected: `"glm-5.3"` and a non-zero `usage` block — proves the `tier-frontier` route resolves to
Z.ai's GLM-5.3 (`modelNameOverride` in `infrastructure/base/llm-gateway/aigatewayroute.yaml`) through
the `/api/paas/v4` prefix, and that a client-supplied `x-ai-gateway-client-id`
is discarded (the real one comes from `apiKeyAuth`, stripped and re-set the same way `agent-router`
handles `x-ar-agent`).

### Step 4 — confirm token usage is attributed to the real client (via the API-server proxy, never a direct VM URL)

```bash
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=sum%20by%20(ar_client)%20(gen_ai_client_token_usage_sum%7Bgen_ai_original_model%3D%22tier-frontier%22%7D)" | jq .
```

Expected: a `promptfoo` series with a non-zero value, and **no** `forged` series.

**What this proves:** the SP4 frontier route works end to end and its usage counter attributes to the
verified client identity, not a client-forged header.

### Step 5 — tokens are charged, in shadow

```bash
kubectl -n envoy-gateway-system port-forward deploy/envoy-ratelimit 19001 &
sleep 2
curl -s localhost:19001/metrics | grep -E 'total_hits|shadow_mode' | head
kill %1
```

Expected: counters above 0 after Step 3. Record the exact metric names seen — the shadow-week
analysis before SP4 PR 7 (budget enforcement) reads them.

### Step 6 — marker probe: prove 429 actually fires

A temporary, route-level `BackendTrafficPolicy` overrides the Gateway-level one (still shadow mode)
on a header only this probe sends. Nothing else on the Gateway changes.

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: zz-budget-marker-probe
  namespace: llm-gateway
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: llm-gateway
  rateLimit:
    global:
      rules:
        - clientSelectors:
            - headers:
                - name: x-budget-probe
                  type: Exact
                  value: marker
          limit: {requests: 1, unit: Hour}
          cost:
            request: {from: Number, number: 0}
            response: {from: Metadata, metadata: {namespace: io.envoy.ai_gateway, key: llm_total_token}}
          shared: true
EOF
sleep 60   # Envoy needs about a minute to program the policy; earlier calls see no rate limit at all
for i in 1 2 3; do curl -sS --cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem -o /dev/null -D - https://llm.priv.$CLOUD.ogenki.io/v1/chat/completions \
  -H "Authorization: Bearer $LLM_API_KEY" -H "Content-Type: application/json" -H "x-budget-probe: marker" \
  -d '{"model":"tier-frontier","messages":[{"role":"user","content":"ok"}]}' | grep -iE '^HTTP|x-ratelimit-(remaining|reset)'; done
kubectl delete btp -n llm-gateway zz-budget-marker-probe
```

Expected: `200`, `200`, then `429 Too Many Requests` with `x-ratelimit-remaining: 0`. The cost is
charged from the *response*, so the call that spends the budget still succeeds and the next one is
refused. Send three calls, not two. There is no `x-envoy-ratelimited` header: detect a budget cut-off
by status 429 (and `x-ratelimit-reset`), which is what the harness's 429 handling (`agent_run.py`)
does.

The bucket is keyed on the rule, not on the header value. A re-run within the hour inherits the spent
bucket and gives `429` from the first call: change the rule (for example its `limit`) for a fresh one.

**What this proves:** SP4's token-cost rate-limiting mechanism actually enforces (200 then 429) when
a rule is not in shadow mode — the three real rules in
`infrastructure/base/llm-gateway/btp-token-budgets.yaml` stay in shadow deliberately (ADR-0050); this
probe is the only way to see enforcement fire before SP4 PR 7 (budget enforcement) turns it on.

### Cleanup

```bash
unset LLM_API_KEY
kubectl delete btp -n llm-gateway zz-budget-marker-probe --ignore-not-found
```

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| A.1 — secrets synced | `Ready=True` ×2, `SecretSynced` | `agent-secrets` and `agent-router` `Ready=True`; SecretStore `agents-secrets` `True`; `agents-zai-api-key` `SecretSynced` | PASS | <!-- pragma: allowlist secret -->
| A.2 — gateway label | 1 pod each | `agent-router`: 2 pods (2 replicas); `ai-gateway`: 1 pod | PASS |
| A.3 — SC-10, cluster half | `0`; ExternalSecret denied | `0` secrets in `agents`. The server-side dry run of `sc10` was refused by `agents-no-secret-import`: `namespace agents holds no secret: External Secrets objects are refused (SP1 S9)` | PASS |
| A.3 — SC-10, OpenBao half | `read,deny,deny,deny` | Needs `bao write auth/jwt/gcp-0/login …`, which mints a token. This session holds no OpenBao token | [OWNER] |
| A.4 — SC-17 listener half | `404`; no `zai` on 8081 | `internal chat 404`; VictoriaLogs: 2 hits on port 8081 in 15 min, both with a null `upstream_cluster` | PASS |
| B.1 — promptfoo key | key fetched, never echoed | Length 48, never printed. The Secret's key is `promptfoo`, not `promptfoo_apikey` as this runbook says (`ai-gateway-api-keys` holds `openwebui,promptfoo`) | PASS |
| B.2 — budget/ratelimit live | `READY True`; `Running 1/1`; `Accepted=True` | KVStore `xplane-ai-gateway-ratelimit` `SYNCED=True READY=True`; `envoy-ratelimit-69b6cdc49f-6ph5c` `1/1 Running`; BTP `Accepted=True Accepted` | PASS |
| B.3 — frontier call | the frontier model, non-zero usage | `"glm-5.3"` (the route now serves GLM-5.3, not 5.2); `{"prompt_tokens":17,"completion_tokens":94,"total_tokens":111}` | PASS |
| B.4 — VM attribution | `promptfoo` series, no `forged` | `ar_client=promptfoo` = `3073`; no `forged` series | PASS |
| B.5 — shadow counters | Non-zero `total_hits` | `ratelimit_service_rate_limit_total_hits` = `739` on `ai-gateway-token-budgets` rule 1 and rule 2; `311` on the marker probe | PASS |
| B.6 — marker probe | `200`, `200`, then `429` | First attempt, 20 s after the apply: `200`, `200` (no rate-limit headers: the policy was not programmed yet), then `200` with `x-ratelimit-remaining: 1`. Second attempt, 60 s after the re-apply: `429 Too Many Requests` ×3, `x-ratelimit-remaining: 0`, `x-ratelimit-reset: 772`. The bucket is keyed on the rule, not on the header value, so it carried over. No `x-envoy-ratelimited` header. Wait about 60 s after the apply | PASS |

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| A.1 — secrets synced | `Ready=True` ×2, `SecretSynced` | `agent-secrets`/`agent-router` both `SUSPENDED=False READY=True`; SecretStore condition `True`; ExternalSecret `agents-zai-api-key` reason `SecretSynced` | PASS | <!-- pragma: allowlist secret -->
| A.2 — gateway label | 1 pod each | `ai-gateway`: 1 pod; `agent-router`: 2 pods (2 replicas, both selected) | PASS |
| A.3 — SC-10 | `0`; ExternalSecret denied; `read,deny,deny` | `0` secrets in `agents`; ExternalSecret denied by `agents-no-secret-import`; capabilities-self of an `agents-secrets` login: `platform/data/agents/zai` read, `platform/data/llm/zai` deny, `apps/data/anything` deny; token revoked (owner's session, `scratchpad/owner/rb04-openbao-scope.sh`) | PASS |
| A.4 — SC-17 listener half | `404`; no `zai` on 8081 | `internal chat 404`; VictoriaLogs: 3 hits on port 8081 in 15m, all with a null `upstream_cluster` (no route matched, so certainly no `zai`) | PASS |
| B.1 — get promptfoo key | key fetched, never echoed | Fetched in the owner's session (length 51), never printed | PASS |
| B.2 — budget/ratelimit live | `READY True`; `Running 1/1`; `Accepted=True` | `xplane-ai-gateway-ratelimit` KVStore `SYNCED=True READY=True`; `envoy-ratelimit-7797cc6985-zqrhj` `1/1 Running`; BTP ancestor `Accepted=True` | PASS |
| B.3 — frontier call | `"glm-5.2"`, non-zero usage | `"glm-5.2"`; `{"prompt_tokens":17,"completion_tokens":93,"total_tokens":110}` | PASS |
| B.4 — VM attribution | `promptfoo` series, no `forged` | `ar_client=promptfoo`, `gen_ai_original_model=tier-frontier`; no `forged` series (needs one scrape interval, ~60 s) | PASS |
| B.5 — shadow counters | Non-zero `total_hits` | `ratelimit_service_rate_limit_total_hits` = 110 on rule 1 and rule 2 (exactly the call's total tokens) | PASS |
| B.6 — marker probe | `200`, `200`, then `429` | `200` (`x-ratelimit-remaining: 1`), `200`, `429 Too Many Requests` (`x-ratelimit-remaining: 0`, `x-ratelimit-reset`); no `x-envoy-ratelimited` header | PASS |
