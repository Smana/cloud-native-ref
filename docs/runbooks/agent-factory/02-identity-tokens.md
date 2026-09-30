# 02 — Identity and tokens

Proves that `agent-router`'s per-listener JWT authentication returns the right 401/403 for every
wrong-token combination and attributes the verified subject correctly (SC-05); that a run's tokens
live until the run's deadline rather than the projected volume's nominal TTL (R2); that the harness
has no channel into the identity-proxy's admin API (Q8); and that deleting a running claim kills the
pod, the GitHub token and a copied gateway token on the documented timescales (SC-07). See
[README.md](README.md) for prerequisites; run [00](README.md#runbook-00-one-time-cluster-setup) and
[01](01-runtime-sandbox.md) first (01 is not a hard dependency, but confirms the platform is up).

## Prerequisites

- Runbook 00 done.
- Owner action 1 done (OpenBao/EKS config applied) — the identity-proxy's tokens and `agent-router`'s
  JWT validation both depend on the per-cluster `jwt/<cluster>` issuer being wired, but this runbook
  itself only needs the EKS OIDC issuer, which exists on any cluster; no Z.ai key is needed here.

> Corrected 2026-09-27: this was numbered "owner action 2" — README's numbering (action 1 =
> OpenBao policy/JWT role, action 2 = the Z.ai key) makes this action 1, which the text's own "no
> Z.ai key is needed here" already implied.

## Part A — SC-05 and Q8, through the identity probe

`scripts/ops/k8s/agent-probe.yaml` is a throwaway `Sandbox` in `agents` that projects all three token
audiences into one pod (`agent-router.implementer.{public,internal}`,
`octo-sts/Smana/cloud-native-ref/implementer`) without running a real agent — exactly what a run's
harness never gets to see directly.

### Step 1 — apply the probe

```bash
kubectl apply -f scripts/ops/k8s/agent-probe.yaml
kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
```

Expected: `Ready`.

### Step 2 — the 401/403 matrix and header-forgery attribution (SC-05)

```bash
R=http://agent-router.envoy-gateway-system.svc.cluster.local
p() { kubectl exec -n agents agent-probe -c probe -- sh -c "$1"; }
p "curl -s -o /dev/null -w 'none→public %{http_code}\n' $R:8080/v1/models"
p "curl -s -o /dev/null -w 'sts→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/sts/token)\" $R:8080/v1/models"
p "curl -s -o /dev/null -w 'internal→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/internal/token)\" $R:8080/v1/models"
p "curl -s -o /dev/null -w 'public→internal %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" $R:8081/v1/models"
p "curl -s -o /dev/null -w 'public→public %{http_code}\n' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" $R:8080/v1/models"
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
FORGED=$(ISSUER="$ISSUER" python3 -c 'import base64,hashlib,hmac,json,os,time
enc=lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
h=enc({"alg":"HS256","typ":"JWT"}); b=enc({"iss":os.environ["ISSUER"],"aud":"agent-router.implementer.public","sub":"system:serviceaccount:agents:forged","exp":int(time.time())+600})
print(h+"."+b+"."+base64.urlsafe_b64encode(hmac.new(b"not-the-issuer-key",(h+"."+b).encode(),hashlib.sha256).digest()).rstrip(b"=").decode())')
p "curl -s -o /dev/null -w 'self-signed→public %{http_code}\n' -H 'Authorization: Bearer $FORGED' $R:8080/v1/models"
p "curl -s -o /dev/null -w 'forged-header %{http_code}\n' -H 'x-ar-agent: agent:forged' -H \"Authorization: Bearer \$(cat /var/run/secrets/probe/public/token)\" -H 'content-type: application/json' -d '{\"model\":\"agent-default\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK.\"}]}' $R:8080/v1/chat/completions"
```

Expected: `none→public 401`, `sts→public 403`, `internal→public 403`, `public→internal 403`,
`public→public 200`, `self-signed→public 401`, `forged-header 200`.

> Corrected 2026-09-27: **`GET /v1/models` bypasses JWT authentication entirely** — verified live,
> every token combination (none, wrong-audience, self-signed-forged) returns `200` on this path. See
> the README's Platform findings. The same matrix run against `POST /v1/chat/completions` instead
> (same headers, plus a JSON body and `content-type`) gives the expected
> `401,403,403,404(structural, see runbook 04 SC-17),200` — the underlying SecurityPolicy/JWT
> mechanism is sound; only the `/v1/models` path is unprotected. Use `/v1/chat/completions` for this
> matrix until the bug is fixed.
>
> Fixed later on 2026-09-27 (#2108, live on `980b789f`). `/v1/models` now gives 401 without a valid
> token, and 404 with one. Either path works for this matrix.

Then confirm the forged `x-ar-agent` header never survives (it is stripped before authentication and
re-set from the verified `sub`):

```bash
curl -s https://vl.priv.gcp.ogenki.io/select/logsql/query --data-urlencode \
  'query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:"agent-router" _time:15m | unpack_json | log.path:"/v1/chat/completions" | fields log.x_ar_agent, log.response_code, log.upstream_cluster'
```

> Corrected 2026-09-27: the access log records the **post-rewrite** path. A rejected call (401/403)
> logs `path:"/v1/chat/completions"` (rewrite never reached), but the one call that succeeds logs
> `path:"/api/paas/v4/chat/completions"` — the exact-match filter above only ever returns the
> rejected rows (`x_ar_agent` empty, as expected for a rejected call) and silently misses the one row
> this step is actually meant to check. Drop the `log.path` filter (or match `*chat/completions`) to
> catch the accepted request too. Verified live: with the filter dropped, the accepted request logs
> `log.x_ar_agent:"system:serviceaccount:agents:agent-probe"`, `log.upstream_cluster` is
> `httproute/agent-system/agent-models/rule/0` (names the route, not a bare `zai` string).

Expected: `log.x_ar_agent` is exactly `system:serviceaccount:agents:agent-probe` — never
`agent:forged`, never both. Upstream cluster names the `zai` backend (in practice, the HTTPRoute
that backs it — see correction above).

**What this proves:** SC-05 — 401 for missing/self-signed tokens, 403 for a valid token of the wrong
audience, and the identity header is always server-derived, never client-supplied.

### Step 3 — Q8: no channel from the harness into the proxy admin API

Note: the probe pod has no `identity-proxy` sidecar of its own, and its `probe` container
(`curlimages/curl`) has no `python3` either — this specific check needs a real run's pod. Repeat it
against a run created in Part B instead (Step 4 there), or against runbook 01's run if it is still
alive:

> Corrected 2026-09-27: removed the `p "python3 ..."` invocation against the probe pod that
> preceded this note in the original text — `curlimages/curl` has no `python3`, so it only ever
> produced `sh: python3: not found` (verified live), never a real signal. The command below,
> against a real run's `harness` container, is the only one that proves anything for Q8.

```bash
kubectl exec -n agents <run-name> -c harness -- /usr/local/bin/python -c "import socket,os; s=socket.socket(); r=s.connect_ex(('127.0.0.1',9901)); print('9901:', 'refused' if r else 'OPEN'); print('admin socket visible:', os.path.exists('/tmp/envoy-admin.sock')); print('hot-restart socket:', 'envoy_domain_socket' in open('/proc/net/unix').read())"
```

Expected: `9901: refused`, `admin socket visible: False`, `hot-restart socket: False`. Any other
answer means the harness has a control channel into the only holder of the run's tokens — stop and
escalate before continuing to any other runbook.

**What this proves:** Q8 — the admin API is a pathname unix socket in an emptyDir the harness
container does not mount, and hot restart (which would open an abstract socket) is disabled.

### Step 4 — clean up the probe (keep it if runbook 04 or 06 runs next in the same session)

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Part B — R2 (token TTL) and SC-07 (revocation timings)

Uses a short, real run so its tokens' TTL is small enough to observe expiry within this session
(`expirationSeconds = max(600, maxMinutes × 60)`, R2).

### Step 1 — start a 10-minute run and capture a token of each kind

```bash
REV=$(task agent:run -- --role implementer --class public --minutes 10 --task "Wait: list the files under docs/ slowly, one per minute. Change nothing." | tail -1); echo "$REV"
kubectl wait -n agents agentrun/$REV --for=jsonpath='{.status.phase}'=Running --timeout=15m
GHT=$(kubectl exec -n agents $REV -c harness -- /usr/local/bin/git-credential-agent token)
GWT=$(kubectl create token $REV -n agents --audience agent-router.implementer.public --duration 10m); ISSUED=$(date +%s)
kubectl apply -f scripts/ops/k8s/agent-probe.yaml && kubectl wait -n agents sandbox/agent-probe --for=condition=Ready --timeout=10m
```

`$GHT` and `$GWT` never leave the shell as printed text — only used as header values below.

> Corrected 2026-09-27: verified live that this run's harness has no admin-API channel (Q8 passed
> on this run's pod, `xplane-run-7q5pwvmp`). Only `$GHT` (via `git-credential-agent`) was refused by
> this session's permission classifier ("Credential Materialization") — `$GWT` (via `kubectl create
> token`) is a plain Kubernetes API call and was **not** blocked; it was captured and used for the
> gateway-token-death timing in Step 2 below, never printed. Recorded `$GHT` as BLOCKED (permission);
> the owner must capture and use it interactively (see the runbook's Results table for the exact
> command). The pod-death half of Step 2 does not need either token: pod gone 3 s after `kubectl
> delete agentrun --wait=false`.

### Step 2 — delete the claim and time each credential's death (SC-07)

```bash
T0=$(date +%s); kubectl delete agentrun -n agents $REV --wait=false
until ! kubectl get pod -n agents $REV >/dev/null 2>&1; do sleep 2; done
echo "pod gone after $(( $(date +%s) - T0 )) s"
until [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GHT" https://api.github.com/installation/repositories)" = 401 ]; do sleep 5; done
echo "GitHub token dead after $(( $(date +%s) - T0 )) s"
until [ "$(kubectl exec -n agents agent-probe -c probe -- curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GWT" http://agent-router.envoy-gateway-system.svc.cluster.local:8080/v1/models)" = 401 ]; do sleep 15; done
echo "copied gateway token dead $(( $(date +%s) - ISSUED )) s after issue"
unset GHT GWT
```

Expected: pod gone ≤ 60 s; GitHub token 401 ≤ 60 s (the `preStop` revoke still reaches
`api.github.com` because the run's `Usage` holds its CNP open until the pod is fully gone); copied
gateway token rejected **around 600 s** after issue, not earlier — a 10-minute run's tokens carry a
600 s TTL (`max(600, 10×60)`), which is R2's whole point: they outlive kubelet's rotation instead of
expiring on the projected volume's nominal shorter TTL.

**What this proves:** SC-07 (revocation timings) and R2 (token TTL = the run's deadline, not a
shorter nominal value — a rotated token never reaches the identity-proxy under gVisor, so the fix is
to make the initial token live long enough).

### Cleanup

```bash
kubectl delete -f scripts/ops/k8s/agent-probe.yaml
```

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| A.1 — probe | `Ready` | `sandbox.agents.x-k8s.io/agent-probe condition met` | PASS |
| A.2 — 401/403 matrix (`/v1/models`) | 401 without a valid token, 404 with one (#2108) | `none→public 401`, `sts→public 403`, `internal→public 403`, `public→internal 404`, `public→public 404`, `self-signed→public 401`. The issuer is `https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0` | PASS |
| A.2 — matrix (`/v1/chat/completions`) | `401,403,403,401,200` | `none→chat 401`, `sts→chat 403`, `internal→chat 403`, `self-signed→chat 401`, `forged-header 200` | PASS |
| A.2 — attribution | `x_ar_agent` = probe's SA, never forged | VictoriaLogs (path matched with `log.path:~"chat/completions"`): the accepted call logs `log.path:"/api/paas/v4/chat/completions"`, `log.x_ar_agent:"system:serviceaccount:agents:agent-probe"`, `200`, `httproute/agent-system/agent-models/rule/0`. The rejected calls carry no `x_ar_agent`, and no row says `agent:forged`. The `vl.priv.gcp.ogenki.io` calls need `--cacert opentofu/gcp/openbao/management/.tls/ca.pem`. Without it, curl under `-s` prints nothing | PASS |
| A.3 — Q8 | `refused` / `False` / `False` | Against `xplane-run-6qnowwxl`'s harness: `9901: refused`; `admin socket visible: False`; `hot-restart socket: False` | PASS |
| B.1 — token TTL | `expirationSeconds = max(600, 10×60)` | `xplane-run-t3g57qb4` (10 min): projected tokens `agent-router.implementer.public` and `octo-sts/…/implementer`, both `exp: 600` | PASS |
| B.2 — pod gone | ≤ 60 s | `pod gone after 16 s` | PASS |
| B.2 — GitHub token dead | ≤ 60 s | Not attempted. Capturing `$GHT` through `git-credential-agent` is credential materialization, which the round-6 classifier refused, so this step stays with the owner, run interactively | [OWNER] |
| B.2 — gateway token dead | ~600 s after issue | The copied token was accepted right after issue (`/v1/models` → `404`). `copied gateway token dead 671 s after issue`: 600 s TTL, plus the 15 s poll, plus the JWT clock-skew leeway | PASS |

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| A.2 — 401/403 matrix (`/v1/models`, as written) | `401,403,403,403,200,401,200` | `none→public 200`, `sts→public 200`, `internal→public 200`, `public→internal 404`, `public→public 200`, `self-signed→public 200`, `forged-header 200` — every token combination, including no token and a self-signed garbage JWT, returns `200` | **FAIL** (see Platform findings — `GET /v1/models` bypasses JWT entirely) |
| A.2 — 401/403 matrix (`/v1/chat/completions`, corrected) | `401,403,403,404,200` | `none→chat 401`, `sts→chat 403`, `internal→chat 403`, `public→internal-chat 404` (structural, SC-17), `public→chat 200` — exactly as expected | PASS |
| A.2 — attribution | `x_ar_agent` = probe's SA, never forged | VictoriaLogs (path filter dropped, see correction): `log.x_ar_agent:"system:serviceaccount:agents:agent-probe"`, `log.response_code:"200"`, `log.upstream_cluster:"httproute/agent-system/agent-models/rule/0"` — never `agent:forged` | PASS |
| A.3 — Q8 | `refused` / `False` / `False` | Run against a real run's harness (`xplane-run-7q5pwvmp`): `9901: refused`; `admin socket visible: False`; `hot-restart socket: False` | PASS |
| B.2 — pod gone | ≤ 60 s | `pod gone after 3 s` | PASS |
| B.2 — GitHub token dead | ≤ 60 s | Not attempted — capturing `$GHT` via `git-credential-agent` was refused by this session's own permission classifier (Credential Materialization) | BLOCKED (owner's session) |
| B.2 — gateway token dead | ~600 s after issue (10-min run) | `$GWT` capture via `kubectl create token` was **not** blocked (never printed). Tested against `/v1/chat/completions`, not `/v1/models` (which never rejects any token — see A.2): `copied gateway token dead 673 s after issue` (15 s poll granularity plus the 60 s pod-death/CNP-teardown window this token's run also went through account for the ~73 s over the nominal 600 s) | PASS |
