# Agent Factory live test session — aws-0

Exercises SP1 (agent runtime and identity) and SP4 PR 1 (AI gateway: frontier route and token budgets) on
the live test cluster `aws-0`. Every command is copy-paste, and every step names its expected output.
Start with [Runbook 00](#runbook-00-one-time-cluster-setup): the cluster is already deployed, but four
owner actions gate most runbooks.

## Status (2026-09-27)

Round 6 covers runbook 07 only. SC-04 passes end to end: an agent took issue #2112 to PR #2114 on the
repo-built harness, and the owner merged it. Rounds 1–5 are recorded below.

Round 4, executed against `aws-0` on `integration/agent-factory` @ `580042e6`. Runbook 05's octo-sts
422 (round 3) is fixed — the App was missing `pull_requests: read & write` and the installation
hadn't accepted the change; both corrected, re-verified live with two real runs (implementer push
to its own branch and rejection on `main`; reviewer push rejected; the audience-mismatch case in
both directions). Runbook 05 is now fully PASS, all tokens revoked, all runs and the one `agent/**`
branch pushed during testing deleted. 01–04, 06, 08 carried over unchanged; 07 unchanged this round
(still gated on the harness-image task-bootstrap gap, #2110).

| Runbook | PASS | FAIL | BLOCKED | Notes |
|---|---|---|---|---|
| [01](01-runtime-sandbox.md) | 9 | 0 | 0 | R7 fails closed by design and resumes via `--branch` (see Platform findings) |
| [02](02-identity-tokens.md) | 5 | 1 | 1 | The 1 FAIL (`/v1/models` auth bypass) is FIXED in #2108 and verified live; GitHub-token timing waits for the harness image |
| [03](03-egress.md) | 6 | 0 | 0 | Fully clean |
| [04](04-gateway-secrets-budgets.md) | 10 | 0 | 0 | Fully PASS — run to completion by the coordinator directly, not re-verified in this session |
| [05](05-github-octo-sts.md) | 12 | 0 | 0 | Fully PASS — the round-3 octo-sts 422 is fixed (see Platform findings); implementer push/reject, reviewer reject, and both wrong-role/audience directions all verified live with real runs |
| [06](06-mcp.md) | 6 | 0 | 0 | Fully clean — `agent-mcp` and both MCPRoutes are `Ready`/`Accepted` now that `agent-router` is up |
| [07](07-end-to-end.md) | 6 | 0 | 1 | Round 6: **SC-04 PASS**. The agent took issue #2112 to PR #2114 in 68 s over 10 steps, and the owner merged it. The round-5 SDK crash and the 30-min timeout are fixed in the harness. SC-06 is unblocked but not yet run |
| [08](08-observability.md) | 5 | 0 | 0 | Dashboard data verified via the same VM/VL proxy calls; UI render itself is SSO-gated, not exercised headlessly |
| **Total** | **59** | **1** | **2** | The one FAIL is 02's `/v1/models`, fixed in #2108. The two open items are 02's GitHub-token timing and 07's SC-06 |

## What each runbook proves

| Runbook | Proves (SC / Q / R) | Needs an owner action? | Est. time |
|---|---|---|---|
| [00](#runbook-00-one-time-cluster-setup) (below, this file) | — (setup only) | Yes — 1–4 (see checklist) | 10 min + owner actions |
| [01-runtime-sandbox.md](01-runtime-sandbox.md) | SC-01, SC-02, SC-03, SC-08, Q1, R7 | No | ~20 min |
| [02-identity-tokens.md](02-identity-tokens.md) | R2 (token TTL), Q8, SC-05, SC-07 | Yes — 1 | ~30 min |
| [03-egress.md](03-egress.md) | SC-09, Q3, Q4 | No | ~15 min |
| [04-gateway-secrets-budgets.md](04-gateway-secrets-budgets.md) | SC-10, SC-17 (listener half), SP4 frontier route + budgets | Yes — 1, 2 | ~20 min |
| [05-github-octo-sts.md](05-github-octo-sts.md) | SC-11, sts listener end to end | Yes — 1, 3, 4 | ~25 min |
| [06-mcp.md](06-mcp.md) | SC-12, SC-17 (MCP half) | Yes — 1 | ~15 min |
| [07-end-to-end.md](07-end-to-end.md) | SC-04, SC-06, SC-13, SC-14 | Yes — 1–5 | ~2 h |
| [08-observability.md](08-observability.md) | Agent-platform VMRules, dashboard, SP4 gateway metrics | No | ~15 min |

**Out of scope tonight:** SC-15/SC-16 (gVisor overhead ratio and `validate-manifests.sh`/`task check`
exit codes) are already closed by the phase-0 spike and by CI — no live step adds evidence. The gcp-0
follow-up is a separate, unscoped design.

## Prerequisites (all runbooks)

- Tailscale up, on the tailnet that reaches `*.priv.aws.ogenki.io`.
- AWS credentials in the environment (`aws sts get-caller-identity` succeeds).
- A kubeconfig context for `aws-0` (`kubectl config current-context`).
- OpenBao CLI, with `VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem`.
- `gh` CLI authenticated as an account that can call the GitHub API for `Smana/cloud-native-ref`.
- **VictoriaMetrics has no trusted-CA path for MCP tools.** Every VM query in these runbooks goes
  through the API server proxy, never a direct URL or an `mcp__victoriametrics__*` tool call:

  ```bash
  kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=<url-encoded-promql>"
  ```

  VictoriaLogs has no such workaround in scope here — its runbooks use
  `curl https://vl.priv.aws.ogenki.io/select/logsql/query` directly.
- **Never put a token or API key on a command line.** Read it into a shell variable from a file,
  `kubectl create token`, or `bao ... -field=token`, and never `echo`/`print` the variable itself —
  only curl's `%{http_code}` or a redacted prefix (`token[:4]`).

## Runbook 00: one-time cluster setup

### What is already in place

`aws-0` tracks `integration/agent-factory`. That branch is never merged. It is the union of:

- every PR of the programme (SP4 PR 1, PRs 2–6);
- the design docs (#2092);
- the Envoy Gateway CRD chore;
- the CC-1 pre-release pin (`v0.7.2-pr27.66f6a76`, which carries the `AgentRun` XRD);
- one test-only commit that sets `spec.suspend: false` on the `ai-gateway` and `agent-platform`
  umbrellas.

Because the umbrellas are unsuspended **in git**, there is nothing to `flux resume`. A live resume
would be reverted on the next `flux-system` reconcile.

```bash
kubectl get gitrepository -n flux-system flux-system -o jsonpath='{.spec.ref.name}{"\n"}'
flux get kustomizations -n flux-system | grep -E '^(ai-gateway|agent-platform)[[:space:]]'
```

> Corrected 2026-09-27: `flux get kustomization` (flux CLI 2.9.5) silently reads only the first
> name given and drops the rest — it never errors, so a multi-name invocation quietly checks one
> Kustomization and reports nothing on the others. Every runbook command below now lists then
> greps instead of passing multiple names positionally.

Expected: `refs/heads/integration/agent-factory`; both `Ready=True`, `Suspended=False`.

> **Footgun.** Any `terramate script run deploy` that touches `eks/configure` must carry
> `TF_VAR_flux_git_ref=refs/heads/integration/agent-factory`. Without it the stack re-points Flux at
> `main`, and every agent resource is pruned.

### Owner actions, in order

| # | Action | Unblocks | Command |
|---|---|---|---|
| 1 | OpenBao policy `agents-secrets` + JWT role `agents-secrets` | `agent-secrets` → `agent-router` → `agent-mcp`, `octo-sts` (runbooks 02, 04–07) | see below |
| 2 | The agents' Z.ai key | runbook 04 (frontier route), 07 | `bao kv put -mount=platform agents/zai api_key=-` (key on stdin, never as an argument) |
| 3 | Branch ruleset, **before** the App exists | runbook 05 | `task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref` |
| 4 | GitHub App `ogenki-agents` on `Smana`, installed on `Smana/cloud-native-ref` only | runbook 05, 07 | `bao kv put -mount=platform agents/github-app app_id=<id> private_key=@<pem file>` |
| 5 | A trivial issue URL (e.g. a broken relative link) | runbook 07 SC-04 | — |

Action 1 is two small, additive stacks, run from a checkout of `integration/agent-factory`:

```bash
cd opentofu
terramate -C aws/openbao/management script run preview    # expect: 1 to add (vault_policy.agents_secrets)
terramate -C aws/openbao/management script run deploy
TF_VAR_flux_git_ref=refs/heads/integration/agent-factory \
  terramate -C aws/eks/configure script run preview        # expect: the agents-secrets JWT role added; nothing else
TF_VAR_flux_git_ref=refs/heads/integration/agent-factory \
  terramate -C aws/eks/configure script run deploy
flux reconcile kustomization agent-secrets -n flux-system --with-source
kubectl get secretstore -n agent-system agents-secrets -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `True`. If the `eks/configure` preview shows anything besides the role, stop. The
checkout is stale or the variable is missing (see the footgun above).

After actions 2 and 4, force the ExternalSecrets to re-read rather than waiting out their interval:

```bash
kubectl annotate externalsecret -n agent-system --all force-sync=$(date +%s) --overwrite
flux get kustomizations -n flux-system | grep -E '^(agent-router|agent-mcp|octo-sts)[[:space:]]'
```

Expected: all three `Ready=True`.

Not needed tonight, and not blocking any runbook: #2092, CC-1 (#27), then the `v0.8.0` tag
and the harness image. Until the image is published, runbook 07 runs on the upstream `agent-server`
image. Note that substitution in its results table.

### Cleanup and teardown

```bash
kubectl delete agentruns -n agents --all --wait
kubectl delete -f scripts/ops/k8s/agent-probe.yaml --ignore-not-found
```

To take the agent platform down while keeping the cluster, revert the test-only unsuspend commit on
`integration/agent-factory` and push. Pointing the cluster back at `main` needs a `TF_VAR_flux_git_ref`
deploy of `eks/configure`, which prunes everything above. Destroying the cluster is a separate owner
call.

## Recording results

Each runbook ends with a results table (step, expected, observed, pass/fail). Fill it in place as
you go — there is no separate consolidated form. Paste failing steps' `kubectl`/`curl` output
verbatim; a summary line ("worked") is not evidence per this repo's evidence rule.

### Platform findings

**FIXED for round 4 (owner) — octo-sts's installation-token mint returned 422 for every trust
policy, both roles tested (round 3).** Cause confirmed by the owner: the `ogenki-agents` App was
missing `pull_requests: read & write`, and the installation had not accepted that permission change.
Both fixed; round 4 re-verified live on real implementer and reviewer runs — exchange, `GET
/repos/...`, push-allowed-to-own-branch, push-refused-to-`main`, push-refused-for-reviewer, and the
audience-mismatch case in both directions all now behave exactly as designed. See runbook 05's
Results table.

<details><summary>Original round-3 write-up</summary>

`agent-router`'s `sts` listener correctly verifies the caller
and forwards to octo-sts (confirmed: cross-repo and non-run-subject requests are denied with the
*right* octo-sts-level errors, not a network failure), but the actual GitHub call octo-sts makes to
mint the scoped installation token always fails:

```
github_api_call method=POST path_raw=/app/installations/165342698/access_tokens status_code=422
```

Reproduced from a real implementer run (`xplane-run-bx7qwi6i`, trust policy `contents:write,
pull_requests:write, issues:read, checks:read, actions:read`) and a real reviewer run
(`xplane-run-iqeuqxbv`, `contents:read, pull_requests:read, issues:read, checks:read, actions:read`)
— both roles' *scoped* mint 422s identically, even though the *unscoped* installation token octo-sts
uses internally to read the trust-policy file from the repo succeeds (`201`) most of the time. Since
both a write-heavy and a read-only permission set fail the same way, the likely cause is a permission
declared in **every** trust policy that the `ogenki-agents` GitHub App installation was not actually
granted — `checks: read` and `actions: read` are the two most easily missed in the App's repository
permissions UI (`docs/superpowers/plans/2026-09-25-agent-runtime-identity-plan.md` line ~5080 has the
intended table). GitHub 422s an installation-token request that asks for a permission the app-level
grant doesn't include. **Owner check:** compare `Smana` → Settings → GitHub Apps → `ogenki-agents` →
Permissions against that table; if it was edited after the initial install, GitHub also requires the
installation to re-accept the updated permission set before tokens honoring it can mint. This blocked
every push-capable path in runbooks 05 and 07 until the round-4 fix above.

</details>

**New, round 5 (2026-09-27, live on `c1691cee`, real harness `v0.1.0-pr2110.d8134ede`) — the
OpenHands SDK crashes on the first model response, every time, before any git operation.** Everything
up to and including the model call works: the run clones the repo, checks out `agent/<id>`, starts a
conversation, and `agent-router` proxies one `POST /api/paas/v4/chat/completions` → `200` in 4539ms
(`glm-5.3`; the gateway meters `8144` tokens for it, `sum(gen_ai_client_token_usage_sum{ar_agent=...})`).
Then, inside the harness's own SDK, before the agent ever acts on that response:

```
AttributeError: 'PromptTokensDetailsWrapper' object has no attribute 'cache_creation_tokens'
  File ".../openhands/sdk/llm/utils/telemetry.py", line 68, in normalize_usage
    cache_write = int(prompt_details.cache_creation_tokens or 0)
openhands.sdk.conversation.exceptions.ConversationRunError: Conversation run failed for id=...
```

A `UserWarning` just before it is the likely root: `Cost calculation failed: This model isn't mapped
yet. model=agent-default, custom_llm_provider=openai` — LiteLLM doesn't recognize `agent-default`,
falls back to a generic OpenAI-shaped response wrapper, and that wrapper's `prompt_tokens_details`
lacks the Anthropic-style `cache_creation_tokens` field `normalize_usage` unconditionally reads.
**Reproduced twice**, back to back (`xplane-run-3s7i55r7`, `xplane-run-mun2l7g2`), both crashing
`phase=Failed`/`PodFailed` 30-45s after `Running`, before any octo-sts exchange or git push — no
branch ever reaches GitHub, no PR is possible. This blocks every real end-to-end run (SC-04, SC-06)
until either the SDK is patched/pinned past this bug or the gateway advertises a model name LiteLLM
maps to a provider whose usage shape it expects. Not fixed here (no code changed).

**New, round 3 (2026-09-27, live on `580042e6`) — the upstream `agent-server` image never submits a
task; an `AgentRun` idles at `Running` doing nothing.** With CC-2/#2110 (the repo-built harness image)
not yet published, the Sandbox's only app container runs the bare OpenHands image with
`command: ["--port","8000"]` — no wrapper reads the composition's `TASK_FILE`/`CONVERSATION_ID` env
vars and calls `POST /api/conversations`. Verified on `xplane-run-n7tfcziv` (issue `#2112`): phase
reached `Running`, `status.conversationId` was allocated, but after 8+ minutes: zero rows for
`sum(gen_ai_client_token_usage_sum{ar_agent="system:serviceaccount:agents:xplane-run-n7tfcziv"})`,
zero `agent-router` access-log lines for that `x_ar_agent`, zero octo-sts activity, no PR. This is a
harder block than "no git credential helper" — the agent loop itself never starts. Expected until
#2110 ships; not fixed here.

> **FIXED 2026-09-27, in #2108 (PR 3, 4fda7196), live on `980b789f`.** The root cause was filter
> order, not the `Overridden` status. On `public` the chain is
> `ext_proc/aigateway → custom_response → jwt_authn → …`, and AI Gateway enables its ext_proc only on
> the `agent-models` routes, where it answers `/v1/models` itself before `jwt_authn` runs.
> A dedicated Exact-path `/v1/models` route with no ext_proc now answers 404 behind the
> listener's JWT policy. CI gate A7 requires that guard on every agent-router listener carrying an
> AIGatewayRoute. Live after the fix:
> - `/v1/models`: no token 401, forged 401, valid 404;
> - chat: no token 401, valid 200, served by `glm-5.3`.
>
> Not covered: the human gateway's `llm.priv…/v1/models` also answers without credentials. It is
> tailnet-only and exposes model names only.

**Round 2 (2026-09-27, live on `580042e6`) — `GET /v1/models` bypasses `agent-router`'s JWT
authentication entirely (SC-05).** Every token combination tested against the public listener's
`/v1/models` returns `200`, including no `Authorization` header at all and a self-signed,
wrong-signature JWT:

```
none→public 200
sts→public 200
internal→public 200
self-signed→public 200
```

The `agent-router-public` SecurityPolicy (JWT, `agent-router.implementer.public` etc. audiences) is
correctly `Accepted=True` but carries an `Overridden=True` condition:

```
message: 'This policy is being overridden by other securityPolicies for these
  routes: [agent-system/ai-eg-mcp-main-agent-mcp-public]'
```

`POST /v1/chat/completions` on the same listener, same Gateway, enforces JWT correctly
(`none→401`, `sts→403`, `internal→403`, `public→200`) — the SecurityPolicy mechanism itself works.
Only the ai-gateway-synthesized `/v1/models` listing bypasses it, most likely because that endpoint
is answered by the `ai-gateway-extproc` filter before the JWT filter runs, independent of the
per-route SecurityPolicy attachment. Anyone with network access to `agent-router` (any pod in the
cluster, absent a CiliumNetworkPolicy restricting it) can currently enumerate configured models with
no credential. Not fixed here per this session's scope (no code changes); use
`/v1/chat/completions` for auth-matrix testing until this is fixed.

**Fixed in git during the round-1 run (live since `76716898`):**
- **`agent-sandbox`:** `reconcileStrategy: Revision` put `+<sha>` into the chart's `helm.sh/chart`
  label, and the API server rejected the release. A postRenderer now replaces the label.
- **`envoy-ai-gateway`:** ESO's second write to the watched MCP seed Secret cancelled an in-flight
  upgrade. The HelmRelease had no upgrade remediation, so it stalled. It now retries.

**R7: a lost pod ends its run as `Failed` and is not recreated.** Runbook 01, Step 7. This is by
design, and Step 7 now tests it that way. The composition's F2b lock withholds the ServiceAccount
once a run is terminal. agent-sandbox v1.0.3 reports `Finished=PodFailed` for every pod that ends in
phase `Failed`, a deleted or evicted pod included. So the composition latches `Failed` before the
Sandbox controller's recreate, which the missing ServiceAccount then refuses:

```
{"level":"info","ts":"...23:49:10Z","msg":"Creating a new Pod", ... "Sandbox":{"name":"xplane-run-kcerjyh5","namespace":"agents"}}
{"level":"error","ts":"...23:49:10Z","msg":"Failed to create", ... "error":"pods \"xplane-run-kcerjyh5\" is forbidden: error looking up service account agents/xplane-run-kcerjyh5: serviceaccount \"xplane-run-kcerjyh5\" not found"}
```

Recovery is the spec's documented mitigation: a new run on the same branch
(`task agent:run -- … --branch agent/<id>`). The spike's "recreated at once, same name" held for the
Sandbox controller alone, before the F2b and M2 locks existed. The spec's R7 text is corrected on
#2092.

Transparent resume would need the composition to see the pod itself (`deletionTimestamp` or a
`DisruptionTarget` condition), so it could tell pod loss from a crash. That is a CC-1 follow-up
for the owner to decide.
