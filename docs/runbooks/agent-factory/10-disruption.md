# 10 — Disruption: a reclaimed run checkpoints and resumes

Proves the [disruption design](../../superpowers/specs/2026-10-04-agent-run-disruption-design.md):
on a reclaim the harness checkpoints its work and lets the room read the log to its end within 15 s,
the `AgentRun` says why it ended, and the factory resumes it on its own. gcp-0 for Steps 1–6; aws-0
for Step 7. See [README.md](README.md) for `CLOUD`; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- `integration/agent-factory` carries `feat/rooms-disruption` and `feat/factory-resume`.
- No `AgentRun` is `Running` when Step 1's pool check is applied (it re-creates the pool's nodes).
- A test issue on `Smana/cloud-native-ref` that a maintainer may label `factory/ready`.

## Steps

### Step 1 — what is deployed

```bash
kubectl get configuration.pkg crossplane-configuration-gcp -o jsonpath='{.spec.package}{"\n"}'
kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane watch pods --all-namespaces
gcloud container clusters describe gcp-0 --location europe-west4-a --format='value(currentMasterVersion)'
gcloud container node-pools describe agents-gvisor --cluster gcp-0 --location europe-west4-a \
  --format='value(config.kubeletConfig.shutdownGracePeriodSeconds,config.kubeletConfig.shutdownGracePeriodCriticalPodsSeconds)'
kubectl get cm -n agent-system agent-factory-config -o jsonpath='{.data.config\.yaml}' | grep -A1 '^resume:'
```

Expected: the `v0.7.2-pr<P>` package; `yes`; a version ≥ `1.35.0-gke.1171000`; `120	15`; `resume:` then `  maxPerTask: 2`.

**What this proves:** the composition, Crossplane's read of run pods, the pool's window and the cap are live.

### Step 2 — start a factory task with uncommitted work

Open an issue with this body, then label it `factory/ready`:

```text
Create the file docs/disruption-probe.md containing the single line "probe". Do not commit it.
Then run `sleep 1200` in the terminal and wait for it to end.
```

```bash
TASK=$(kubectl get task -n agent-system --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}'); echo "$TASK"
until kubectl get agentrun -n agents -l agents.ogenki.io/task=$TASK -o name | grep -q .; do sleep 5; done
RUN=$(kubectl get agentrun -n agents -l agents.ogenki.io/task=$TASK -o jsonpath='{.items[0].metadata.name}'); echo "$RUN"
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Running --timeout=15m
```

Wait until the step log shows the `sleep 1200` action:
`kubectl logs -n agents $RUN -c harness | grep -m1 'sleep 1200'`.

### Step 3 — simulate a Spot preemption of its node

```bash
NODE=$(kubectl get pod -n agents $RUN -o jsonpath='{.spec.nodeName}')
ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
T0=$(date -u +%FT%TZ)
gcloud compute instances simulate-maintenance-event $NODE --zone $ZONE
kubectl get pod -n agents $RUN -w -o jsonpath='{.status.phase} {.status.reason} {range .status.conditions[?(@.type=="DisruptionTarget")]}{.reason}{end}{"\n"}'
```

Expected: the pod ends `Failed Terminated TerminationByKubelet`. If `simulate-maintenance-event` is refused for a Spot VM,
`gcloud compute instances stop $NODE --zone $ZONE` sends the same ACPI soft-off; record which one ran.

### Step 4 — the run's end

```bash
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Failed --timeout=5m
kubectl get agentrun -n agents $RUN -o jsonpath='{.status.phase} {.status.reason}{"\n"}'
```

Expected: `Failed Disrupted`.

The shutdown, from VictoriaLogs (the pod is gone; `kubernetes.pod_name` is the run's pod):

```text
_time:30m kubernetes.pod_name:"<RUN>" kubernetes.container_name:"harness" "agent-run shutdown"
```

Expected: five lines, in order `pause`, `checkpoint`, `final-read`, `stop`, `revoke`; `checkpoint done: pushed a checkpoint commit`;
`final-read done: {"events": …, "unmirrored": 0, …}`; the five durations sum under 15 s. Record each duration.

The checkpoint on the branch:

```bash
gh api "repos/Smana/cloud-native-ref/commits?sha=agent/$TASK&per_page=3" --jq '.[0].commit.message'
gh api "repos/Smana/cloud-native-ref/contents/docs/disruption-probe.md?ref=agent/$TASK" --jq '.content' | base64 -d
```

Expected: a message ending with `Agent-Run: <run id>` and `Agent-Checkpoint: disruption`; `probe`.

The transcript's tail in the room (`events` is the number the final read answered):

```bash
PSQL="kubectl exec -n agent-system xplane-rooms-cnpg-cluster-1 -c postgres -- psql -d rooms -tA -c"
$PSQL "SELECT max(origin_seq) / 4 FROM events WHERE room_id = '$TASK' AND origin_client = 'agent:${RUN#xplane-run-}'"
```

Expected: equal to the final read's `events`.

**What this proves:** acceptance criteria 1, 2 and 3 (`Disrupted`), and the 15 s budget under gVisor.

### Step 5 — the automatic resume

```bash
gh issue view <issue> --repo Smana/cloud-native-ref --comments | grep 'resuming automatically'
kubectl wait -n agent-system task/$TASK --for=jsonpath='{.status.resumes}'=1 --timeout=5m
until RUN2=$(kubectl get agentrun -n agents -l agents.ogenki.io/task=$TASK --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}') && [ "$RUN2" != "$RUN" ]; do sleep 5; done
kubectl get task -n agent-system $TASK -o jsonpath='{.status.phase} {.status.resumes} {.status.runs[-1:].trigger}{"\n"}'
kubectl get agentrun -n agents $RUN2 -o jsonpath='{.spec.branch} {.spec.roomRef}{"\n"}'
```

Expected: `… the sandbox was lost (spot reclaim or eviction); resuming automatically (1/2).`; `Implementing 1 resume`;
`agent/<TASK> <TASK>`. On the factory dashboard, *Automatic resumes by reason* shows `Disrupted` = 1; the run page of `$RUN`
(`/d/agent-run/agent-run?var-run=${RUN#xplane-run-}`: the page takes the run id) lists `${RUN2#xplane-run-}` under *Runs of this task*.

### Step 6 — a plain delete reads PodLost and resumes; a third loss escalates

```bash
kubectl wait -n agents agentrun/$RUN2 --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl delete pod -n agents $RUN2 --wait=false
kubectl wait -n agents agentrun/$RUN2 --for=jsonpath='{.status.phase}'=Failed --timeout=5m
kubectl get agentrun -n agents $RUN2 -o jsonpath='{.status.reason}{"\n"}'
kubectl wait -n agent-system task/$TASK --for=jsonpath='{.status.resumes}'=2 --timeout=5m
until RUN3=$(kubectl get agentrun -n agents -l agents.ogenki.io/task=$TASK --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}') && [ "$RUN3" != "$RUN2" ]; do sleep 5; done
kubectl wait -n agents agentrun/$RUN3 --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl delete pod -n agents $RUN3 --wait=false
kubectl wait -n agent-system task/$TASK --for=jsonpath='{.status.phase}'=Escalated --timeout=5m
kubectl get task -n agent-system $TASK -o jsonpath='{.status.reason}{"\n"}'
```

Expected: `PodLost`; the `resumes` wait met; after the third loss `resumes_exhausted`, with no fourth run.

**What this proves:** acceptance criteria 3 (`PodLost`) and 4 (the cap).

Cleanup: label the issue `factory/stop`, close the PR the runs opened, delete the branch `agent/$TASK`.

### Step 7 — aws-0: does the kubelet's shutdown complete on a Spot interruption?

On aws-0, with a factory implementer `Running` (Step 2's issue, on aws-0). The FIS role and the
experiment template come with the cluster, from
[`opentofu/aws/eks/init/fis.tf`](../../../opentofu/aws/eks/init/fis.tf). The template interrupts
only a running Spot instance tagged `agents.ogenki.io/fis-target=true`, so tag the run's node
first:

```bash
NODE=$(kubectl get pod -n agents $RUN -o jsonpath='{.spec.nodeName}')
IID=$(kubectl get node $NODE -o jsonpath='{.spec.providerID}' | awk -F/ '{print $NF}')
TPL=$(aws fis list-experiment-templates --query "experimentTemplates[?tags.Name=='agent-run-disruption'].id | [0]" --output text)
aws ec2 create-tags --resources $IID --tags Key=agents.ogenki.io/fis-target,Value=true
aws fis start-experiment --experiment-template-id $TPL
```

Then Step 4's and Step 5's checks. Record:

| Outcome | Reading | §5 decision |
|---|---|---|
| The kubelet's shutdown completed | the pod `Failed` with `DisruptionTarget=TerminationByKubelet`, five `agent-run shutdown` lines, `Disrupted` | No early warning on aws-0 |
| It did not | no shutdown lines, the pod stale until PodGC, `PodLost` | Build §5's early warning: a follow-up design chooses the broker watch or a NodePool `terminationGracePeriod` |

Cleanup: `aws ec2 delete-tags --resources $IID --tags Key=agents.ogenki.io/fis-target`, so the next
experiment cannot pick this instance up if the interruption did not take it.

## Results

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 | package, `yes`, version, `120 15`, cap | | |
| 3 | `Failed Terminated TerminationByKubelet` | | |
| 4 | `Failed Disrupted`; five lines < 15 s; trailer; `probe`; room tail = `events` | | |
| 5 | narration (1/2); `Implementing 1 resume`; same branch and room | | |
| 6 | `PodLost`; `resumes` = 2; `Escalated resumes_exhausted` | | |
| 7 | the outcome and the §5 decision | | |
