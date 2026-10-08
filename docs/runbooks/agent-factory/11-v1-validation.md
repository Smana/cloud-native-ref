# 11 — v1 and local-first UX validation

Proves the [local-first UX design](../../superpowers/specs/2026-10-08-agent-factory-local-first-ux-design.md)
([ADR-0056](../../../website/content/docs/decisions/0056-local-first-factory-ux.md)) on a cluster pinned to the
agent-platform `v0.8.0` release, and closes SP3 Task 10.6 Step 2 (one task end to end on release pins). aws-0.
See [README.md](README.md) for `CLOUD`; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- aws-0 runs `agent-platform` `v0.8.0` (factory, room-broker, `roomctl`) with `human.access` set in
  [`infrastructure/base/room-broker/config.yaml`](../../../infrastructure/base/room-broker/config.yaml), and
  the link-only GitHub IdP from `scripts/provision/zitadel-idp.sh` is provisioned.
- The platform CA, needed up front: `roomctl` talks to the room broker and the room page is served at
  `https://rooms.priv.aws.ogenki.io`, both private endpoints signed by that CA, and the same CA signs every
  private endpoint in Step 6. `roomctl` has no `--cacert` flag, so fetch the chain below, then trust the root
  certificate (CN=Ogenki Root CA, the last certificate in `ca.pem`) in the OS trust store — for example
  `sudo trust anchor --store <root>.pem` on Linux (p11-kit). Without it, `roomctl rooms` fails with
  `tls: failed to verify certificate: x509: certificate signed by unknown authority` before Step 1:

  ```bash
  scripts/provision/openbao-config.sh ca --root-ca-secret-name certificates/priv.aws.ogenki.io/ca-chain \
    --ca-output-file ca.pem --region eu-west-3 --profile ""
  ```

- `roomctl` `v0.8.0`, verified: `sha256sum -c --ignore-missing roomctl.sha256`, then `roomctl configure` and `roomctl login`
  as an `agents-admin` (the room list's *CLI setup* view prints the values).
- A second identity, a ZITADEL user who is **not** `agents-admin`, with `roomctl` logged in on its own config. Call it `dev2`.
- A **private** test repo `dev2` cannot read, with a factory task in it. Call it `<private-repo>`.
- A test issue on `Smana/cloud-native-ref` that a maintainer may label `factory/ready`.

## Steps

### Step 1 — a local agent drafts and files an issue

In a checkout of `Smana/cloud-native-ref`, with `.agents/skills/factory-handoff/` present
(`.claude/skills` is a symlink to it), ask the local agent: "hand this to the factory: fix the broken relative link in
`<file>`". Then read what it filed:

```bash
test -L .claude/skills && ls .claude/skills/factory-handoff/SKILL.md
gh issue list --repo Smana/cloud-native-ref --author @me --limit 1 --json number,title,labels,body
```

Expected: the skill file resolves through the symlink; the issue is filed with the template's sections and **no** `factory/ready`
label. Add the label yourself: `gh issue edit <issue> --repo Smana/cloud-native-ref --add-label factory/ready`.

**What this proves:** the skill drafts and files, and starting the factory stays a human act (D1).

### Step 2 — `roomctl status --json`

```bash
TASK=$(kubectl get task -n agent-system --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}'); echo "$TASK"
roomctl status "$TASK" --json > status.json
jq -e '.apiVersion=="summary/v1" and has("status") and has("needsYou") and has("actions") and .notes.untrusted==true and (.cursor|startswith("seq:"))' status.json
roomctl status "$TASK" --json --after "$(jq -r .cursor status.json)" | jq .notes
```

Expected: `jq -e` prints `true` (exit 0); the phase, run, budget, PR once opened, `needsYou`, the notes and the cursor are present.
The `--after` call returns only notes newer than the cursor (none when nothing was posted since).

**What this proves:** the summary contract the skill and the page both read.

### Step 3 — the room page

Open `https://rooms.priv.aws.ogenki.io/r/$TASK` as `agents-admin`, then as a user who only has the watcher role.

Expected: the status, needs-you, actions and notes blocks render, and the raw log is folded. The watcher sees **no** actions
block. Open `https://rooms.priv.aws.ogenki.io/r/$TASK#<approvalId>` for an approval listed under needs-you: the page scrolls to
and highlights that approval's card.

**What this proves:** the five-block page, the per-viewer view, and the approval deep link.

### Step 4 — a diagram zooms

Open any page of the docs site with a mermaid diagram, for example
`https://cnref.ogenki.io/docs/platform/ai-platform/agents/user-guide/`. Click the diagram, then wheel-zoom and drag. Toggle the
theme and repeat.

Expected: full screen on click; zoom and pan work; the diagram is legible in the light and the dark theme; `Esc` closes it.

**What this proves:** the zoomable-diagram partial
([`website/layouts/_partials/custom/head-end.html`](../../../website/layouts/_partials/custom/head-end.html)).

### Step 5 — D7 room access, as `dev2`

Each check names its identity. The cache is 5 minutes (`human.access.ttl`).

```bash
roomctl rooms                                  # dev2, before linking GitHub
roomctl rooms | grep -c "$TASK"               # after linking, no read on the repo
roomctl status "<private-room>"               # same identity
DEV2_TOKEN=$(roomctl token)                   # dev2's config; never echoed
curl -sSI -H "Authorization: Bearer $DEV2_TOKEN" https://rooms.priv.aws.ogenki.io/api/rooms | grep -i x-rooms-access
```

The `X-Rooms-Access` header (R21) reads `unlinked` before `dev2` links GitHub (5a) and `ok` after (5b onward). `unverified`
(GitHub or ZITADEL unreachable) is covered by the broker's unit tests: an outage cannot be induced safely on the live cluster.

| # | Check | Expected |
|---|---|---|
| 5a | `dev2`, GitHub **not** linked: `roomctl rooms` | The unlinked hint (link GitHub in your ZITADEL profile); no room listed |
| 5b | `dev2` links GitHub, has no read on `<private-repo>`: `roomctl rooms`, `roomctl status <private-room>`, and the page URL | The private room is not listed; `status` and the page answer 404, never 403 |
| 5c | Grant `dev2` read on `<private-repo>` on GitHub; poll `roomctl rooms` every 30 s | The room appears within 5 minutes |
| 5d | Open the room's WebSocket as `dev2` (the page, or `roomctl watch <room>`), then revoke `dev2`'s read | The socket is cut within TTL + 30 s (5 min 30 s) |
| 5e | R26: `dev2` signs in to ZITADEL with the GitHub button | The sign-in succeeds (accepted, ADR-0056). Then deactivate the ZITADEL user: the next `roomctl rooms` and the next page load are refused |
| 5f | R14 premise: the deployed ZITADEL version | v4.17.3, v4.18.0 or later: from those releases a user cannot add an IdP link to their own account without `user.write`, so the GitHub login the broker reads is the one a GitHub sign-in or an admin put there |

```bash
kubectl get deploy -n security zitadel -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Older releases skip `user.write` when the caller targets their own account (`AddUserIDPLink` in
`internal/command/user_idp_link.go`). A live probe of 5f (`POST /v2/users/{id}/links` for `dev2`'s own id) needs a `dev2` token
whose audience includes ZITADEL's API; a `roomctl` token is refused with `401 Errors.Token.Invalid` before any permission check,
on a vulnerable release as on a fixed one, so it proves nothing.

**What this proves:** a room is as visible as its repo on GitHub, fails closed, follows revocation, and the
accepted risk of GitHub sign-in is understood (R14, R26).

### Step 6 — observability on one run

Pick a run of `$TASK`:

```bash
RUN=$(kubectl get agentrun -n agents -l agents.ogenki.io/task=$TASK -o jsonpath='{.items[0].metadata.name}'); RUNID=${RUN#xplane-run-}; echo "$RUN"
```

The private endpoints need `--cacert ca.pem` (Prerequisites). The VictoriaLogs MCP server does not trust that CA, so use `curl`.

**Logs:**

```bash
curl -sS --cacert ca.pem https://vl.priv.aws.ogenki.io/select/logsql/query \
  --data-urlencode "query=kubernetes.pod_name:\"$RUN\" | stats by (kubernetes.container_name) count() hits"
```

Expected: rows for the `harness`, `room-bridge`, `room-gate` and `identity-proxy` containers.

**Metrics** (a scrape in the first minute can read 0; query again after the meter has written):

```bash
curl -sS --cacert ca.pem https://vm.priv.aws.ogenki.io/api/v1/query --data-urlencode "query=agentrun_usage_tokens{run_id=\"$RUNID\"}"
curl -sS --cacert ca.pem https://vm.priv.aws.ogenki.io/api/v1/query --data-urlencode 'query=agent_factory_kill_switch_engaged'
```

Expected: a non-zero token count; `agent_factory_kill_switch_engaged` `0`.

**Traces:**

```bash
curl -sS --cacert ca.pem "https://vt.priv.aws.ogenki.io/select/jaeger/api/traces?service=agent-harness&lookback=1h" \
  | jq '[.data[] | {traceID, runs: ([.spans[].tags[] | select(.key=="agent.run_id") | .value] | unique)}]'
```

Expected: one trace per task, whose spans carry `agent.run_id` for every run of the task.

The factory's root span (service `agent-factory`) is exported only once the task ends, so run this check **after Step 7**.
Fetch the trace by its id and assert the root is the ancestor of every run's spans:

```bash
TRACE=$(curl -sS --cacert ca.pem "https://vt.priv.aws.ogenki.io/select/jaeger/api/traces?service=agent-factory&lookback=2h" \
  | jq -r '.data[0].traceID')
curl -sS --cacert ca.pem "https://vt.priv.aws.ogenki.io/select/jaeger/api/traces/$TRACE" | jq -e '
  .data[0] as $t
  | ($t.processes | map_values(.serviceName)) as $svc
  | ($t.spans | map({key: .spanID, value: (.references[0].spanID // null)}) | from_entries) as $parent
  | ($t.spans | map(select($svc[.processID] == "agent-factory" and .references == []))) as $roots
  | ($t.spans | map(select(any(.tags[]; .key == "agent.run_id")))) as $runs
  | def top: if $parent[.] == null then . else ($parent[.] | top) end;
    ($roots | length) == 1 and ($runs | length) > 0
    and all($runs[]; .spanID | top == $roots[0].spanID)'
```

Expected: `true` (exit 0): one parentless `agent-factory` span, and the parent chain (`references`) of every span carrying
`agent.run_id` ends at it. Check that the distinct `agent.run_id` values equal the task's runs; a chain that ends elsewhere is a fail.

**Dashboards:** in Grafana (`https://grafana.priv.aws.ogenki.io`), `agent-run` (`/d/agent-run/agent-run?var-run=$RUNID`) and
`agent-fleet` show this task's run, tokens and phase.

**Alert:** an `AgentRun` takes its image from the composition, so use a bare `Sandbox` with an image that cannot be pulled. The
alert needs the pod `Pending` for 15 minutes. Write `/tmp/podpending-probe.yaml` (Write tool, not a heredoc):

```yaml
apiVersion: agents.x-k8s.io/v1beta1
kind: Sandbox
metadata: {name: podpending-probe, namespace: agents}
spec:
  service: false
  shutdownPolicy: Delete
  podTemplate:
    spec:
      automountServiceAccountToken: false
      runtimeClassName: gvisor
      restartPolicy: Never
      securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: probe
          image: registry.invalid/does-not-exist:0
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
```

```bash
kubectl apply -f /tmp/podpending-probe.yaml
kubectl get pod -n agents podpending-probe -o jsonpath='{.status.phase} {.status.containerStatuses[0].state.waiting.reason}{"\n"}'
# after 15 minutes:
curl -sS --cacert ca.pem https://vm.priv.aws.ogenki.io/api/v1/query --data-urlencode 'query=ALERTS{alertname="AgentSandboxPodPending",alertstate="firing"}'
```

Expected: `Pending ErrImagePull` or `ImagePullBackOff`; the `ALERTS` series for `AgentSandboxPodPending` after 15 minutes.
Kyverno may refuse the manifest. If it does, record the refusal reason as this step's evidence and fall back to the AgentRun path
the factory uses.

Cleanup: `kubectl delete sandbox podpending-probe -n agents && rm /tmp/podpending-probe.yaml`.

**What this proves:** a run is visible in logs, metrics, traces and both dashboards, and a stuck pod pages.

### Step 7 — SP3 10.6 Step 2: one task end to end on release pins

A task must be (re)started with a fresh `factory/ready`. A `/factory retry` only acts on a task that exists in the current
cluster, and a rebuilt cluster has none.

```bash
kubectl get configuration.pkg -o custom-columns=NAME:.metadata.name,PKG:.spec.package
gh issue edit <issue> --repo Smana/cloud-native-ref --add-label factory/ready
until kubectl get task -n agent-system -o name | grep -q .; do sleep 5; done
TASK=$(kubectl get task -n agent-system --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
for i in $(seq 240); do
  PHASE=$(kubectl get task -n agent-system $TASK -o jsonpath='{.status.phase}')
  case "$PHASE" in Done|Rejected|NoOp|Reverted|Escalated|Closed|Stopped) break ;; esac
  sleep 10
done; echo "terminal phase: $PHASE"
gh pr list --repo Smana/cloud-native-ref --head agent/$TASK --json number,state,author
```

Expected: release pins only (no `-pr<N>` suffix); the happy path runs `… AwaitingHuman → Merged → Verifying → Done`, with a PR
opened by `app/ogenki-agents`, a reviewer verdict on it, and the room page and `roomctl status` agreeing. The other terminal
phases (`Rejected`, `NoOp`, `Reverted`, `Escalated`, `Closed`, `Stopped`) are a fail for this step.

**What this proves:** the whole path works on released artifacts, and unblocks FR-10's merge.

## Results

aws-0 on agent-platform `v0.8.0` and crossplane-configuration `v0.9.3`, 2026-10-08. `TASK=yacoriey` (issue
[#2266](https://github.com/Smana/cloud-native-ref/issues/2266), PR [#2267](https://github.com/Smana/cloud-native-ref/pull/2267)).

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 | issue filed by the skill, no `factory/ready` | The skill resolved through the symlink, showed the draft, filed #2266 after confirmation with labels `[]`; the owner labelled it | Pass |
| 2 | `summary/v1` fields; `--after` returns only newer notes | `jq -e` → `true` (cursor `seq:4`, phase `Implementing`, `issue.labelledBy: Smana`); `--after seq:4` → no notes. No agent posted a note during the task, so "only newer" was never exercised | Partial |
| 3 | five blocks, raw log folded, watcher sees no actions, `#<approvalId>` lands | Owner, as `agents-admin`: blocks render, raw log folded. No watcher identity in the room and no approval in an unattended task | Partial |
| 4 | diagram full screen, zoom and pan, both themes | Owner, on the user guide | Pass |
| 5a | unlinked hint, no room, `X-Rooms-Access: unlinked` | `dev2` (`agents-member`): empty table plus the hint; `HTTP 200`, `x-rooms-access: unlinked`; `roomctl status yacoriey` on a public repo → "no such room" | Pass |
| 5b | private room unlisted, 404 on `status` and the page, `X-Rooms-Access: ok` | Not run: `dev2` had no GitHub account | Open |
| 5c | room appears within 5 min of the grant | Not run, as 5b | Open |
| 5d | open WebSocket cut within 5 min 30 s of the revoke | Not run, as 5b | Open |
| 5e | GitHub sign-in works; deactivating the ZITADEL user cuts access | Not run, as 5b | Open |
| 5f | ZITADEL ≥ v4.17.3 / v4.18.0 | `ghcr.io/zitadel/zitadel:v4.19.2`, whose `AddUserIDPLink` checks `user.write` for the caller's own account, as does v4.19.4, the latest release. No live probe: `dev2` held only a `roomctl` token | Partial |
| 6 | logs, metrics, traces, dashboards, `AgentSandboxPodPending` | Logs: harness 815, room-bridge 270, identity-proxy 2, room-gate 1. Tokens 505,528 + 162,350 = the task's 667,878; kill switch `0`. One trace (376 spans, one parentless `agent-factory` root, both run ids), root-span `jq -e` → `true`. Dashboards: owner. Alert firing at 13:19:05, 16.5 min after the probe | Pass |
| 7 | one task end to end on release pins | v0.7.0: `d66mo4b4` (#2240 → #2264) Done. v0.8.0: `yacoriey` (#2266 → #2267) implementer, reviewer approve, owner merge, Done | Pass |

5 pass, 3 partial, 4 open (5b–5e, every check that needs `dev2`'s GitHub account).

Findings, each filed where it is fixed:

| Finding | Filed |
|---|---|
| The CA prerequisite was listed for Step 6 only; `roomctl` fails with `x509` before Step 1 | #2266, fixed by the factory in #2267 |
| Onboarding takes six manual steps whose errors (`no such host`, `x509`) do not name the cause | agent-platform [#48](https://github.com/Smana/agent-platform/issues/48) |
| The `factory-handoff` skill has no setup path | agent-platform [#49](https://github.com/Smana/agent-platform/issues/49) |
| `roomctl rooms` shows random ids, the room's phase instead of the task's, and no issue or PR | agent-platform [#50](https://github.com/Smana/agent-platform/issues/50) |
| A task waiting for a merge has an empty `needsYou`, and nothing says the merge needs the ruleset bypass | agent-platform [#51](https://github.com/Smana/agent-platform/issues/51) |
| The closing comment under-reports tokens (553 k against 667,878) | agent-platform [#42](https://github.com/Smana/agent-platform/issues/42), still open on v0.8.0 |
| The spec calls the factory multi-repo; it takes issues from one repository | [#2268](https://github.com/Smana/cloud-native-ref/issues/2268) |
| The unlinked hint says to link GitHub from the login page, which sends a Google-only user to a password reset | [#2269](https://github.com/Smana/cloud-native-ref/issues/2269) |
