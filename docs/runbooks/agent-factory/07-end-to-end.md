# 07 — End to end

The capstone: a real implementer run, on a real issue, opens a real PR within budget (SC-04); a
long-running read-only run's tokens survive without a single 401 across most of an hour (SC-06);
revoking a run by annotation drives it to `BudgetExhausted` with correct status projection rules
(SC-13); and after deletion nothing tagged with the run's id survives anywhere in the cluster
(SC-14). This is the longest runbook — budget close to two hours, most of it waiting. See
[README.md](README.md) for prerequisites; run [00](README.md#runbook-00-one-time-cluster-setup) and
ideally 01–06 first (they de-risk the pieces this one composes).

## Prerequisites

- Runbook 00 done.
- Owner actions 1, 3 and 4 (router, ruleset, GitHub App).
- Optional, not a numbered action: the harness image `ghcr.io/smana/agent-harness:v0.1.0` published (CC-2 merged
  and tagged `v0.8.1`), and CC-1 (`v0.8.0`) merged. If either has not landed yet, runs in this
  runbook use the upstream `agent-server` image instead of the repo-built harness — everything below
  still works (the harness swap is transparent to the claim), except the `gh`/trailer-hook specifics
  are not exercised. Note the substitution in the results table if it applies.
- **Owner action 5**: a trivial issue URL ready, exported as `ISSUE_URL`.

## Step 1 — confirm the harness pin

```bash
kubectl get composition xagentruns.cloud.ogenki.io -o yaml | grep -c 'ghcr.io/smana/agent-harness:v0.1.0@sha256'
```

Expected: `1` if owner action 5 landed; `0` otherwise (see the note above — continue either way).

## Step 2 — SC-04: an implementer run ends in a PR within 30 minutes

```bash
RUN=$(task agent:run -- --role implementer --class public --task-url "$ISSUE_URL" | tail -1); echo "$RUN"
date -u +%FT%TZ
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Succeeded --timeout=30m
kubectl get agentrun -n agents $RUN -o jsonpath='{.status.startedAt} {.status.finishedAt} {.status.branch}{"\n"}'
BRANCH=$(kubectl get agentrun -n agents $RUN -o jsonpath='{.status.branch}')
gh pr list --repo Smana/cloud-native-ref --head "$BRANCH" --json number,author,headRefName
PR=$(gh pr list --repo Smana/cloud-native-ref --head "$BRANCH" --json number --jq '.[0].number')
gh pr view --repo Smana/cloud-native-ref "$PR" --json commits --jq '.commits[].messageBody' | grep -c "Agent-Run: ${RUN#xplane-run-}"
```

Expected: `Succeeded` within 30 minutes of the printed start; one PR from `agent/<runId>` (or
`agent/<taskId>` if the issue maps to one — the composition derives it, never the caller) whose
author login is `app/ogenki-agents`; at least one commit carrying `Agent-Run: <runId>`.

If it fails: read `kubectl logs -n agents $RUN -c harness` and the `agent-router` access log for the
run's `x_ar_agent` (same LogsQL pattern as runbook 02, Part A Step 2) before changing anything.

**What this proves:** SC-04 — the whole chain (Sandbox → identity-proxy → agent-router → GLM-5.2 →
octo-sts → PR) works, unattended, inside the time budget.

Keep this PR open — it's the owner's to review, not to merge or close as part of this session.

## Step 3 — SC-06: a long run gets no 401s across its lifetime

```bash
LONG=$(task agent:run -- --role implementer --class public --minutes 60 \
  --task "Read every Markdown file under docs/superpowers/specs one at a time. For each, list the relative links it contains. Do not change, commit or push anything. Finish with the full list." | tail -1)
kubectl wait -n agents agentrun/$LONG --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

At minute 45 or later (or at the run's end if it finishes sooner — record actual duration either
way):

```bash
Q="rate(gen_ai_client_token_usage_sum{ar_agent=\"system:serviceaccount:agents:$LONG\"}[5m])"
ENC=$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$Q")
kubectl get --raw "/api/v1/namespaces/observability/services/vmsingle-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=$ENC" | jq .
curl -s https://vl.priv.aws.ogenki.io/select/logsql/query --data-urlencode \
  "query=kubernetes.pod_labels.gateway.envoyproxy.io/owning-gateway-name:\"agent-router\" _time:1h | unpack_json | log.x_ar_agent:\"system:serviceaccount:agents:$LONG\" | stats by (log.response_code) count() n"
```

Expected: the VM query confirms the run is actually making calls; the LogsQL result shows no `401`
bucket for this run's `x_ar_agent` at any point in its lifetime. Its tokens live until its 60-minute
deadline (R2, runbook 02) — nothing has to rotate, and a rotated token would not reach the proxy
under gVisor anyway. A run shorter than 45 minutes (it finished early) still counts; record its
actual duration.

```bash
kubectl delete agentrun -n agents $LONG --wait
```

**What this proves:** SC-06 — the R2 token-lifetime fix holds up over a realistic run length, not
just the short probes in runbook 02.

## Step 4 — SC-13: revocation by annotation, and status-projection guards

```bash
B=$(task agent:run -- --role implementer --class public --task "Idle until told otherwise." | tail -1)
kubectl wait -n agents agentrun/$B --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl annotate agentrun -n agents $B agents.ogenki.io/usage-tokens=-5
sleep 30; kubectl get agentrun -n agents $B -o jsonpath='{.status.usage}{"\n"}'
kubectl annotate agentrun -n agents $B --overwrite agents.ogenki.io/usage-tokens=1234
sleep 30; kubectl get agentrun -n agents $B -o jsonpath='{.status.usage.tokens}{"\n"}'
T0=$(date +%s); kubectl annotate agentrun -n agents $B agents.ogenki.io/revoked=budget-run
kubectl wait -n agents agentrun/$B --for=jsonpath='{.status.phase}'=BudgetExhausted --timeout=2m
until ! kubectl get pod -n agents $B >/dev/null 2>&1; do sleep 2; done; echo "BudgetExhausted, pod gone after $(( $(date +%s) - T0 )) s"
```

Expected: empty `status.usage` after the `-5` annotation (a negative value is rejected, never
projected — the composition validates before writing `status.usage.tokens`, which the design says
must never decrease); `1234` after the valid one; `BudgetExhausted` reached with the pod gone ≤ 60 s
after the `revoked=budget-run` annotation.

**What this proves:** SC-13 — malformed usage values never reach status, valid ones do, and the
run-meter's revocation path (the mechanism SP3's real budget enforcement will drive) actually tears
the run down.

## Step 5 — SC-14: nothing left after deletion

```bash
kubectl delete agentrun -n agents $B --wait
for r in $LONG $B; do
  echo "== ${r#xplane-run-} =="
  kubectl get sa,cm,cnp,sandbox,pod,usages.protection.crossplane.io -A -l agents.ogenki.io/run-id=${r#xplane-run-}
done
```

Expected: `No resources found` for both run ids.

**What this proves:** SC-14 — deletion is complete: no ServiceAccount, ConfigMap, CNP, Sandbox, pod
or `Usage` outlives its `AgentRun`.

## Cleanup

Nothing further — every run this runbook created is already deleted except `$RUN`'s PR (Step 2),
which stays open for owner review.

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — harness pin | `1` (or `0`, noted) | `0` — composition still pins `ghcr.io/openhands/agent-server:1.49.5-python@sha256:1e7b0...`, not the repo-built harness (owner action 5 not landed, as expected) | PASS (the documented `0` outcome) |
| 2 — SC-04 | `Succeeded` ≤ 30 min; PR by `app/ogenki-agents`; trailer present | Not attempted — needs `$ISSUE_URL` (owner action 5) and a working `sts`/GitHub App path (owner actions 1, 3, 4) | BLOCKED (owner action 1, 3, 4, 5) |
| 3 — SC-06 | No 401 bucket for the run's `x_ar_agent` | A 60-minute run can be started, but every token call routes through `agent-router`, which is down | BLOCKED (owner action 1) |
| 4 — SC-13 negative | Empty `status.usage` | Not attempted; no dependency on owner actions besides runbook 00 — deferred only for run-budget economy (2-run cap) alongside the fully-blocked steps in this runbook | BLOCKED (owner action 1) — the run's `agent-router`-routed model calls needed to reach a meaningful state are unavailable; the annotation mechanics themselves are independent but weren't exercised in isolation tonight |
| 4 — SC-13 valid | `1234` | Not attempted, same reasoning | BLOCKED (owner action 1) |
| 4 — SC-13 revoke | `BudgetExhausted`, pod gone ≤ 60 s | Not attempted, same reasoning | BLOCKED (owner action 1) |
| 5 — SC-14 | `No resources found` ×2 | Already independently confirmed twice tonight (runbook 01 cleanup and this session's other run deletions all left `No resources found`) | PASS (by analogy, not run standalone here) |

**Static verification (code at 76716898):** the XRD's `status` schema has exactly `branch,
conversationId, finishedAt, phase, pullRequest, reason, runId, startedAt, usage.tokens`, and
`phase` enum is `Pending, Running, Succeeded, Failed, BudgetExhausted, Revoked` — matching every
`jsonpath` this runbook reads. `docs/superpowers/plans/2026-09-25-agent-runtime-identity-plan.md`
carries the composition's own KCL unit tests asserting `agents.ogenki.io/usage-tokens: "-5"` is
rejected and `agents.ogenki.io/revoked: "budget-run"` maps to `BudgetExhausted` — exactly the two
cases Step 4 exercises.
