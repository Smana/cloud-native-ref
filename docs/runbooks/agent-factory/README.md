# Agent Factory live test session — aws-0

Exercises SP1 (agent runtime and identity) and SP4 PR 1 (AI gateway: frontier route and token budgets) on
the live test cluster `aws-0`. Every command is copy-paste, and every step names its expected output.
Start with [Runbook 00](#runbook-00-one-time-cluster-setup): the cluster is already deployed, but four
owner actions gate most runbooks.

## Status after the night run (2026-09-27)

Executed against `aws-0` on `integration/agent-factory` @ `76716898`. Owner actions 1–5 were not
done (as expected — see the checklist below), so most later runbooks are BLOCKED; every blocked
step still got its static check against the code/live XRD. Two mixed rows (04's A.2 and A.3, each
half-PASS/half-BLOCKED) are folded into that runbook's BLOCKED count below — see its own results
table for the split.

| Runbook | PASS | FAIL | BLOCKED | Notes |
|---|---|---|---|---|
| [01](01-runtime-sandbox.md) | 9 | 0 | 0 | R7 fails closed by design and resumes via `--branch` (see Platform findings) |
| [02](02-identity-tokens.md) | 2 | 0 | 4 | `agent-router` down (action 1); credential capture refused by this session's own permission classifier |
| [03](03-egress.md) | 6 | 0 | 0 | Fully clean |
| [04](04-gateway-secrets-budgets.md) | 1 | 0 | 8 | Part A gated by actions 1–2; Part B gated by a permission refusal on the API key fetch |
| [05](05-github-octo-sts.md) | 0 | 0 | 9 | Gated by actions 1, 3, 4; every claim statically verified against the code instead |
| [06](06-mcp.md) | 1 | 0 | 5 | Gated by action 1 (`agent-mcp` depends on `agent-router`) |
| [07](07-end-to-end.md) | 2 | 0 | 5 | Gated by actions 1, 3, 4, 5; harness-pin check confirms the documented `0`/upstream-image fallback |
| [08](08-observability.md) | 5 | 0 | 0 | Dashboard data verified via the same VM/VL proxy calls; UI render itself is SSO-gated, not exercised headlessly |
| **Total** | **26** | **0** | **31** | |

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

### Platform findings (2026-09-27 night run)

**Fixed in git during the run (live since `76716898`):**
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
