# Agent Factory live test session — gcp-0

Exercises SP1 (agent runtime and identity), SP4 PR 1 (AI gateway: frontier route and token budgets)
and the agent observability work on the live test cluster `gcp-0`. Every command is copy-paste, and every step names its expected output.
Start with [Runbook 00](#runbook-00-one-time-cluster-setup): the cluster is already deployed, but four
owner actions gate most runbooks.

## Status (2026-10-01)

gcp-0 is the live target since 2026-09-29. Rounds 1–6 ran on aws-0, which was destroyed on 2026-09-29.

| Runbook | Round 7, gcp-0 (PASS/FAIL/OWNER) | Round 9, gcp-0 (PASS/FAIL/OWNER) | Still open |
|---|---|---|---|
| [01](01-runtime-sandbox.md) | 7 / 1 / 1 | 1 / 1 / 0 | Step 2's FAIL (F2) is fixed (d9d75413, 5b77d0db) and passed from zero in round 9. Step 7: F12. Step 4 (SC-02) is aws-0 only |
| [02](02-identity-tokens.md) | 8 / 0 / 1 | — | B.2 GitHub-token timing needs the owner's interactive session (credential capture) |
| [03](03-egress.md) | 6 / 0 / 0 | — | — |
| [04](04-gateway-secrets-budgets.md) | 10 / 0 / 1 | — | A.3's OpenBao half mints a token: owner |
| [05](05-github-octo-sts.md) | 12 / 0 / 0 | — | — |
| [06](06-mcp.md) | 7 / 0 / 0 | — | The `room_*` tools (since c6a56f78) are not yet observed live in Steps 3–4 |
| [07](07-end-to-end.md) | 1 / 0 / 0 | — | Only SC-04 is recorded on gcp-0 (issue #2140 → PR #2141) |
| [08](08-observability.md) | 5 / 0 / 1 | 9 / 1 / 2 | Step 10's FAIL (F18) is fixed in 60e02d9a; re-run pending. F16 |
| [10](10-disruption.md) | — | — | Ran on aws-0 on 2026-10-07 (v3 @ `1d288ea6`): Steps 1–7 PASS, acceptance 1–6 met, §5 decided (no early warning on aws-0). gcp-0 not run yet |
| **Total** | **56 / 1 / 4** | **10 / 2 / 2** | |

Round 7 ran on `integration/agent-factory` @ `a2c645ba`, round 9 on `147819ff`. Round 9 re-ran only 01
Steps 2 and 7 (as the F2 smoke probe and a room run) and 08 Steps 6–10.

Open bugs the runbooks keep their intended expectation for, with a "Known issue" note at the step:

| Bug | What you see today | Runbook |
|---|---|---|
| F12 | A deleted run pod is re-created within ~1 s, the run stays `Running`, and the harness re-runs the task | 01 Step 7 |
| F15 | A run refused the room's lease still executes its task, unmirrored, on the room's branch | rooms only, no step here |
| F16 | Each MCP call through `agent-router` opens its own root trace instead of joining the run's | 08 Step 8 |

### Latest aws-0 result per runbook (history)

Mixes rounds 4 to 6 (from `580042e6` on). Round 6 took issue #2112 to PR #2114 (SC-04) and ran a
58-minute run with no `401` (SC-06).

| Runbook | PASS | FAIL | BLOCKED | Notes |
|---|---|---|---|---|
| [01](01-runtime-sandbox.md) | 9 | 0 | 0 | R7 fails closed by design and resumes via `--branch` (see Platform findings) |
| [02](02-identity-tokens.md) | 5 | 1 | 1 | The FAIL (`/v1/models` auth bypass) is fixed in #2108 and verified live. GitHub-token timing needs the owner's interactive session (credential capture) |
| [03](03-egress.md) | 6 | 0 | 0 | — |
| [04](04-gateway-secrets-budgets.md) | 10 | 0 | 0 | Run by the coordinator directly |
| [05](05-github-octo-sts.md) | 12 | 0 | 0 | The round-3 octo-sts 422 is fixed (see Platform findings) |
| [06](06-mcp.md) | 6 | 0 | 0 | — |
| [07](07-end-to-end.md) | 7 | 0 | 0 | Round 6: SC-04 (68 s to a PR the owner merged), SC-06 (58 min, 44 × `200`, 0 × `401`) |
| [08](08-observability.md) | 5 | 0 | 0 | Data verified through the VM/VL proxy calls. The UI is SSO-gated |
| **Total** | **60** | **1** | **1** | |

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
| [08-observability.md](08-observability.md) | Agent-platform VMRules, dashboard, SP4 gateway metrics, the per-run view (SO-1…SO-5) | No | ~15 min |
| [09-app-key-compromise.md](09-app-key-compromise.md) | The App key-compromise procedure (SD14): stop, rotate, reload, revoke, resume and audit, for all four Apps | Yes — the App's installation page and settings | ~20 min |
| [10-disruption.md](10-disruption.md) | Disruption design acceptance 1–6 | Yes — a maintainer's `factory/ready`; aws-0 Step 7 needs IAM | ~60 min |

**Out of scope:** SC-15/SC-16 (gVisor overhead ratio and `validate-manifests.sh`/`task check`
exit codes) are already closed by the phase-0 spike and by CI — no live step adds evidence.

## Prerequisites (all runbooks)

Every runbook starts from the repository root with `CLOUD` set. gcp-0 is the live target; the aws
variants are kept for the next aws-0 rebuild.

```bash
CLOUD=gcp    # or aws
```

| | gcp-0 | aws-0 |
|---|---|---|
| kube context | `gke_ogenki-435905_europe-west4-a_gcp-0` | the EKS context of `aws-0` |
| Tailnet reaches | `*.priv.gcp.ogenki.io` | `*.priv.aws.ogenki.io` |
| Cloud credentials | gcloud ADC (`gcloud auth application-default print-access-token >/dev/null && echo ADC-OK`) | `aws sts get-caller-identity` |
| gVisor node label | `sandbox.gke.io/runtime=gvisor` (GKE Sandbox pool) | `agents.ogenki.io/runtime=gvisor` (Karpenter pool) |

- No command here needs AWS credentials on gcp-0: gcp-0 generates its own gateway client keys
  in-cluster (runbook 04 Part B's promptfoo key).
- OpenBao CLI, with `VAULT_ADDR=https://bao.priv.$CLOUD.ogenki.io:8200` and
  `VAULT_CACERT=opentofu/$CLOUD/openbao/management/.tls/ca.pem`.
- `gh` CLI authenticated as an account that can call the GitHub API for `Smana/cloud-native-ref`.
- **VictoriaMetrics: through the API server proxy only**, never a direct URL or an
  `mcp__victoriametrics__*` tool call (no trusted-CA path):

  ```bash
  kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=<url-encoded-promql>"
  ```

- **Every curl to a private host carries the private CA:**
  `--cacert opentofu/$CLOUD/openbao/management/.tls/ca.pem`. Without it, `curl -s` prints nothing.
- **Never put a token or API key on a command line.** Read it into a shell variable from a file,
  `kubectl create token`, or `bao ... -field=token`, and never `echo`/`print` the variable itself —
  only curl's `%{http_code}` or a redacted prefix (`token[:4]`).
- **A run that must still exist later needs a paced task.** An "Idle. Do nothing" task now finishes in
  about a minute, and the pod goes with it. Use `Run 'sleep N' in the terminal, then finish.`

## Runbook 00: one-time cluster setup

### What is already in place

gcp-0 tracks `integration/agent-factory`. That branch is never merged. It is the union of:

- SP1 PRs 2–6 and SP4 PR 1;
- SP2's collaboration rooms (room-broker, room log), SP3's factory (`tooling-agent-factory`) and the
  agent observability work;
- the GCP parity work and its gcp-0 fixes;
- the design docs (#2092) and the Envoy Gateway CRD chore;
- the crossplane-configuration pre-release pin (`v0.7.2-pr35.465e19f`, PR #35), which carries the
  `AgentRun` XRD and the room-bridge sidecar;
- one test-only commit that sets `spec.suspend: false` on the `ai-gateway` and `agent-platform`
  umbrellas.

The branch's own log is the authoritative list.

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

> **Footgun.** Deploy `*/openbao/management` and the cluster's `configure` stack only from an
> `integration/agent-factory` checkout, with `TF_VAR_flux_git_ref`: from `main`, the `agents` mount
> is destroyed and the agent platform pruned.

### Owner actions, in order

| # | Action | Unblocks | Command |
|---|---|---|---|
| 1 | OpenBao policy `agents-secrets` + JWT role `agents-secrets` on `jwt/<cluster>` — applied by the `opentofu/$CLOUD/openbao/management` stack | `agent-secrets` → `agent-router` → `agent-mcp`, `octo-sts` (runbooks 02, 04–07) | see below |
| 2 | The agents' Z.ai key | runbook 04 (frontier route), 07 | `bao kv put -mount=agents zai api_key=-` (key on stdin, never as an argument) |
| 3 | Branch ruleset, **before** the App exists | runbook 05 | `task ops:github:agent-branch-ruleset -- Smana/cloud-native-ref` |
| 4 | GitHub App `ogenki-agents` on `Smana`, installed on `Smana/cloud-native-ref` only | runbook 05, 07 | `bao kv put -mount=agents github-app app_id=<id> private_key=@<pem file>` |
| 4b | The `factory-app` GitHub App key, read by SP3's ExternalSecret `agent-factory-github` | the `agent-factory` Kustomization | `bao kv put -mount=agents factory-app app_id=<id> private_key=@<pem file>` |
| 5 | A trivial issue URL (e.g. a broken relative link) | runbook 07 SC-04 | — |

These three keys (2, 4, 4b) are the platform's one owner-written exception: GitHub and Z.ai issue
them, and the AWS snapshot cannot be restored across KMS seals (GCP parity). Once per GCP lineage.

Action 1 is already applied by the management stack. See
[`clusters/gcp-0-agent-platform/README.md`](../../../clusters/gcp-0-agent-platform/README.md#resume)
for the full resume sequence (`opentofu/gcp/openbao/management` then `opentofu/gcp/gke/configure`,
the latter needing `TF_VAR_flux_git_ref` on a feature-branch cluster) if it ever needs re-applying on
a fresh lineage. To confirm it is live:

```bash
flux reconcile kustomization agent-secrets -n flux-system --with-source
kubectl get secretstore -n agent-system agents-secrets -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `True`.

After actions 2 and 4, force the ExternalSecrets to re-read rather than waiting out their interval:

```bash
kubectl annotate externalsecret -n agent-system --all force-sync=$(date +%s) --overwrite
flux get kustomizations -n flux-system | grep -E '^(agent-router|agent-mcp|octo-sts|agent-factory)[[:space:]]'
```

Expected: all four `Ready=True`.

Runs use the repo-built harness, pinned by the composition as a pre-release
(`agent-harness:v0.2.0-pr2142.10c062c2`) until its plain tag ships.

### Cleanup and teardown

```bash
kubectl delete agentruns -n agents --all --wait
kubectl delete -f scripts/ops/k8s/agent-probe.yaml --ignore-not-found
```

To take the agent platform down while keeping the cluster, revert the test-only unsuspend commit on
`integration/agent-factory` and push. Pointing the cluster back at `main` needs a `TF_VAR_flux_git_ref`
deploy of the cluster's `configure` stack, which prunes everything above. Destroying the cluster is a separate owner
call.

## Recording results

Each runbook ends with a results table (step, expected, observed, pass/fail). Fill it in place as
you go — there is no separate consolidated form. Paste failing steps' `kubectl`/`curl` output
verbatim; a summary line ("worked") is not evidence per this repo's evidence rule.

### Platform findings

**FIXED in round 6: a deleted run's CNP went before its pod, so the GitHub-token revoke could not
reach GitHub (SC-07).** Two defects:
- **The `Usage` was keyed on the Sandbox.** The Usage that should hold the run's CNP until the pod is
  gone named the Sandbox as its `by` resource. A Sandbox has no finalizer and leaves the API the
  moment it is deleted. Crossplane releases a composed Usage as soon as a GET of `by` returns
  NotFound (`internal/controller/protection/usage/reconciler.go:327`, v2.4.2), and replayed the CNP
  deletion in the same second.
- **The harness profile never set `preStop`.**

The consequences: once the CNP was gone, the namespace `default-deny` cut the pod's egress while
`agent-run` was still revoking, so the token stayed live until GitHub expired it, up to 1 h.

| Run | Endpoint removed | CNP deleted |
|---|---|---|
| Before: `qeh6rf2k` (B.2) | 09:52:32 | 09:52:11.6, **21 s before the pod** |
| After: `hb545ti2` | 10:38:37.1 | 10:38:40.3, **3 s after the pod** |

The fix:
- crossplane-configuration PR #29 `4857e3f` adds the `preStop` revoke.
- crossplane-configuration PR #29 `c304bbf` keys the Usage on the **Pod**, which stays in the API until kubelet has finished
  `preStop` and the SIGTERM cleanup.
- #2110 `17ec1f97` grants Crossplane `get pods` in `agents` only. Checked with `kubectl auth can-i`:
  `get` yes; `list`, and `get` in any other namespace, no. Without it the Usage could never release,
  and run deletion would hang.

Rolled out as `v0.7.2-pr29.3ad168a`. The earlier round's `usage_order_live.sh` (on the PR #27 pin) had
passed only because the upstream image died within its 2 s poll.

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

**FIXED in round 6, by OpenHands 1.49.6 with litellm `<1.95.1` (software-agent-sdk#5213) in the
harness. Round 5 (2026-09-27, live on `c1691cee`, real harness `v0.1.0-pr2110.d8134ede`) — the
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

**FIXED by #2110 (the repo-built harness). Round 3 (2026-09-27, live on `580042e6`) — the upstream
`agent-server` image never submits a task; an `AgentRun` idles at `Running` doing nothing.** With the
repo-built harness image (#2110) not yet published, the Sandbox's only app container runs the bare OpenHands image with
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
> listener's JWT policy. Check A7 in `scripts/ci/flux-schema/assert-ai-gateway.py` requires that guard on every agent-router listener carrying an
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
design, and Step 7 now tests it that way. The composition withholds the run's ServiceAccount once
the run is terminal. agent-sandbox v1.0.3 reports `Finished=PodFailed` for every pod that ends in
phase `Failed`, a deleted or evicted pod included. So the composition latches `Failed` before the
Sandbox controller's recreate, which the missing ServiceAccount then refuses:

```
{"level":"info","ts":"...23:49:10Z","msg":"Creating a new Pod", ... "Sandbox":{"name":"xplane-run-kcerjyh5","namespace":"agents"}}
{"level":"error","ts":"...23:49:10Z","msg":"Failed to create", ... "error":"pods \"xplane-run-kcerjyh5\" is forbidden: error looking up service account agents/xplane-run-kcerjyh5: serviceaccount \"xplane-run-kcerjyh5\" not found"}
```

Recovery is the spec's documented mitigation: a new run on the same branch
(`task agent:run -- … --branch agent/<id>`). The spike's "recreated at once, same name" held for the
Sandbox controller alone, before the composition withheld the ServiceAccount and suspended a finished
Sandbox. The spec's R7 text is corrected on #2092.

> Known issue (F12, round 9): on `147819ff`, a deleted run pod was re-created within ~1 s, the run
> stayed `Running`, and the harness re-ran the task in a fresh conversation. That run had a
> `roomRef`; round 7 on a run without one still saw `Failed PodFailed`.

Transparent resume would need the composition to see the pod itself (`deletionTimestamp` or a
`DisruptionTarget` condition), so it could tell pod loss from a crash. That is a crossplane-configuration
follow-up for the owner to decide.
