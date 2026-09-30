# 01 — Runtime and sandbox

Proves that an `AgentRun` actually boots a gVisor-sandboxed pod on the dedicated `agents-gvisor`
Karpenter pool, that the pinned `runsc` release is installed correctly on the node, that admission
control rejects a malformed pod or claim before it can run, that the harness has no Kubernetes API
access, and that a deleted sandbox pod comes back under its own name. See [README.md](README.md) for
prerequisites and the owner actions; run [00](README.md#runbook-00-one-time-cluster-setup) first.

## Prerequisites

- Runbook 00's first check passes (`integration/agent-factory` tracked, both umbrellas `Ready`).
- No owner action specific to this runbook.

## Steps

### Step 1 — confirm the platform is up

```bash
flux get kustomizations -n flux-system | grep -E '^(agent-platform|agent-sandbox|agents-nodepool|runtimeclass-gvisor|agent-runtime|agent-policies)[[:space:]]'
kubectl get xrd agentruns.cloud.ogenki.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}{"\n"}'
kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane create sandboxes.agents.x-k8s.io -n agents
```

> Corrected 2026-09-27: `flux get kustomization` only reads the first positional name (flux CLI
> 2.9.5); list-then-grep instead.

Expected: every listed Kustomization `Ready=True`; `True`; `yes`.

**What this proves:** the umbrella and its children reconciled, the `AgentRun` XRD is installed, and
Crossplane's aggregate ClusterRole (`agent-sandbox:aggregate-to-crossplane`) actually grants it
`Sandbox` writes.

### Step 2 — start a run and time the node (Q1)

```bash
T0=$(date +%s)
RUN=$(task agent:run -- --role implementer --class public --minutes 15 --task "Idle. Do nothing, change nothing." | tail -1); echo "$RUN"
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Running --timeout=15m
NODE=$(kubectl get pod -n agents $RUN -o jsonpath='{.spec.nodeName}')
kubectl get node "$NODE" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.lastTransitionTime}{"\n"}{end}'
kubectl get pod -n agents $RUN -o jsonpath='{.status.startTime}{"\n"}'
echo "elapsed: $(( $(date +%s) - T0 )) s"
kubectl get events -n agents --field-selector involvedObject.name=$RUN,reason=FailedCreatePodSandBox -o name | wc -l
```

Expected: `Running`; a node Ready timestamp shortly before the pod's `startTime`; the
`FailedCreatePodSandBox` count small (0–1) and not climbing if you re-run the last line a minute
later. The phase-0 spike measured ~34 s node-Ready-to-container-start and ~90 s submission-to-start
on a fresh node — a first run on an empty pool should land in the same range, not minutes longer.

**What this proves:** Q1 — no unresolved race between kubelet coming up and gVisor/user-data
finishing on a freshly launched `agents-gvisor` node.

### Step 3 — SC-01: the pod is actually sandboxed

```bash
kubectl get pod -n agents $RUN -o jsonpath='{.spec.runtimeClassName} {.spec.nodeName}{"\n"}'
kubectl get node "$NODE" -o jsonpath='{.metadata.labels.agents\.ogenki\.io/runtime}{"\n"}'
kubectl exec -n agents $RUN -c harness -- dmesg | head -3
kubectl exec -n agents $RUN -c harness -- grep Seccomp /proc/self/status
```

Expected: `gvisor <node>`; `gvisor`; a `Starting gVisor...` banner line; `Seccomp: 0` (`oci-seccomp`
is deliberately off — gVisor does not honour `errnoRet`, so `RuntimeDefault` would block every
glibc ≥ 2.34 thread start; see gvisor#14688).

**What this proves:** SC-01.

### Step 4 — SC-02: runsc is registered correctly on the node

```bash
kubectl debug node/"$NODE" -n default --profile=general --image=public.ecr.aws/amazonlinux/amazonlinux:2023 -- chroot /host bash -c '
  /usr/local/bin/runsc --version | head -1
  containerd config dump | grep -A4 "runtimes.runsc"
  cat /etc/containerd/runsc.toml'
sleep 20; kubectl logs -n default "$(kubectl get pods -n default -o name | grep node-debugger | head -1)"
kubectl get pods -n default -o name | grep node-debugger | xargs -r kubectl delete -n default
```

Expected: `runsc version release-20260921.0`; the runsc runtime under the **v3** CRI plugin id with
`ConfigPath = "/etc/containerd/runsc.toml"`; `oci-seccomp = "false"`.

**What this proves:** SC-02.

### Step 5 — SC-08: the harness has no Kubernetes API access

```bash
kubectl exec -n agents $RUN -c harness -- ls /var/run/secrets/kubernetes.io ; echo "exit=$?"
kubectl exec -n agents $RUN -c harness -- /usr/local/bin/python -c "import urllib.request; urllib.request.urlopen('https://kubernetes.default.svc', timeout=5)" ; echo "exit=$?"
```

Expected: `No such file or directory`, `exit=2`; a connection/name-resolution or timeout error,
`exit=1` — `automountServiceAccountToken: false` on the composed ServiceAccount and no `kube-apiserver`
egress in the run's CNP.

**What this proves:** SC-08.

### Step 6 — SC-03: admission rejects a bad pod and a bad claim

Both test pods below carry a full restricted `securityContext` on purpose — PSS `restricted` runs
before Kyverno and would otherwise deny them first, proving nothing about `agents-pod-shape`.

```bash
kubectl apply --dry-run=server -n agents -f - <<'YAML' 2>&1 | grep -c 'every pod in agents runs under RuntimeClass gvisor'
apiVersion: v1
kind: Pod
metadata: {name: sc03-runc}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: busybox
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
YAML
kubectl apply --dry-run=server -n agents -f - <<'YAML' 2>&1 | grep -c 'a pod in agents never mounts a Kubernetes API token'
apiVersion: v1
kind: Pod
metadata: {name: sc03-token}
spec:
  runtimeClassName: gvisor
  automountServiceAccountToken: true
  securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: busybox
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
YAML
```

Expected: `1` and `1` (each pod denied by `agents-pod-shape` with its own message). If a `0` prints,
re-run without the `grep` and read which admission control actually denied it.

Write `/tmp/agentrun-bad.yaml` (Write tool, not a heredoc):

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: xplane-run-7f3cq2xz, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, branch: main, task: {text: x}}
---
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata: {name: run-1, namespace: agents}
spec: {role: implementer, repository: Smana/cloud-native-ref, principal: "human:1", dataClass: public, task: {text: x}}
```

```bash
kubectl apply --dry-run=server -f /tmp/agentrun-bad.yaml
```

Expected: both claims denied — the first for `spec.branch: main` (must start with `agent/`, an XRD
OpenAPI `pattern` constraint, not CEL — the error reads `spec.branch in body should match
'^agent/[a-z0-9][a-z0-9._/-]{0,100}$'`), the second for its name (must match
`^xplane-run-[a-z2-7]{8}$` — the XRD's own CEL rule fires first and reads exactly `an AgentRun is
named xplane-run-<runId>, runId being 8 characters of [a-z2-7]`; the `agentrun-admission` Kyverno
policy carries the identical message as a second layer, but the CRD-level CEL check rejects the
object before any webhook runs, so Kyverno's copy is never the one you actually see here). Record
each denial message.

> Corrected 2026-09-27: the branch check is a schema `pattern`, not a CEL rule — the error format
> differs from the name check's CEL message. Verified live: both denied as above (dry-run=server).

**What this proves:** SC-03.

### Step 7 — R7: a lost pod ends the run, and a new run resumes its branch

A lost pod (spot interruption, eviction, `kubectl delete`) ends its run as `Failed`. It does not come
back. The Sandbox controller does try to recreate it, but first the pod passes through phase `Failed`.
agent-sandbox v1.0.3 then reports `Finished=PodFailed`, the same as for a crash. The composition
latches `Failed` and withholds the ServiceAccount (F2b), so the recreate is refused. That is the
fail-closed design. Recovery is a new run on the same branch.

```bash
BRANCH=$(kubectl get agentrun -n agents $RUN -o jsonpath='{.status.branch}'); echo "$BRANCH"
kubectl delete pod -n agents $RUN --wait=true
kubectl wait -n agents agentrun/$RUN --for=jsonpath='{.status.phase}'=Failed --timeout=2m
kubectl get agentrun -n agents $RUN -o jsonpath='{.status.phase} {.status.reason}{"\n"}'
kubectl get sa -n agents $RUN 2>&1 | tail -1
RUN2=$(task agent:run -- --role implementer --class public --minutes 15 --branch "$BRANCH" --task "Idle. Do nothing, change nothing." | tail -1)
kubectl wait -n agents agentrun/$RUN2 --for=jsonpath='{.status.phase}'=Running --timeout=15m
kubectl get agentrun -n agents $RUN2 -o jsonpath='{.status.branch}{"\n"}'
```

Expected:
- `Failed PodFailed`;
- `Error from server (NotFound)` for the old run's ServiceAccount;
- the new run `Running` on the same `$BRANCH`.

The controller's `serviceaccount "xplane-run-<id>" not found` log line is the F2b lock working, not
an error.

> Corrected 2026-09-27: this step used to expect the pod to be recreated under the same name. The
> spike proved that for the Sandbox controller alone, before the F2b and M2 locks existed. Live
> evidence: README "Platform findings".

**What this proves:** R7 as built. A lost pod fails closed, and `agent-run --branch` resumes the work.

### Cleanup

```bash
kubectl delete agentrun -n agents $RUN $RUN2 --wait
kubectl get sa,cm,cnp,sandbox,pod,usages.protection.crossplane.io -n agents -l agents.ogenki.io/run-id=${RUN#xplane-run-}
```

Expected: `No resources found` (this doubles as an early look at SC-14, fully proven in runbook 07).

## Results

### Round 7 — gcp-0, 2026-09-30 (`integration/agent-factory` @ `a2c645ba`)

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — platform up | All `Ready=True`; XRD `True`; `yes` | `agent-platform`, `agent-sandbox`, `agent-runtime`, `agent-policies` `Ready=True`. `agents-nodepool` and `runtimeclass-gvisor` do not exist on gcp-0: the pool and the RuntimeClass are GKE-managed (GP-9, GP-10). XRD `Established=True`; `can-i` = `yes` | PASS |
| 2 — Q1 timing | Node Ready ≤ pod start; small `FailedCreatePodSandBox` count | `xplane-run-6qnowwxl`: node Ready `20:25:32Z`, pod start `20:27:57Z`, harness started `20:28:33Z`, 0 × `FailedCreatePodSandBox`, but submission to `Running` took 343 s. **The race Q1 asks about exists on gcp-0.** On a freshly scaled gVisor node, cilium-operator logged `Restarting unmanaged pod` for six of the ten run pods this round created (`4iv2rpdq`, `j2qh5avm`, `x5hf55tr`, `6qnowwxl`, `pttpamhs`, `x6jexfi4`), 53 s to 2 min 31 s after they started. Each of the six had landed on a node that was minutes old; the four that landed on a warm node were left alone. The pods tolerate `node.cilium.io/agent-not-ready` (Ruling Z1), so they land before the Cilium agent is ready. A run whose pod is still Pending survives, because the Sandbox recreates the pod. A run that already reached `Running` fails for good, as R7 designs: `xplane-run-j2qh5avm` was `Running` at 20:19:12, its pod was deleted at 20:19:19, and the run ended `Failed PodFailed`. `xplane-run-pttpamhs` (the first SC-06 attempt) ended the same way. On a warm node, `zt7vyyi6` went from `Pending` to `Running` in 29 s | **FAIL** (see `results-gcp-0-2026-09-30.md`, F2) |
| 3 — SC-01 | `gvisor`/`gvisor`/gVisor banner/`Seccomp: 0` | `gvisor gke-gcp-0-nap-e2-standard-4-1h1w69k1-…`; node label `sandbox.gke.io/runtime=gvisor` (gcp-0 has no `agents.ogenki.io/runtime` label); `Starting gVisor...`; `Seccomp:\t0`; `uname -r` = `4.4.0` | PASS |
| 4 — SC-02 | pinned `runsc`, v3 plugin id, `oci-seccomp = "false"` | Not run. The step is AWS-shaped: its `amazonlinux` image, `/usr/local/bin/runsc` and `/etc/containerd/runsc.toml` do not apply to GKE Sandbox, where Google manages `runsc`. The privileged `kubectl debug node/…` adapted for GKE was refused by this session's permission classifier | [OWNER] |
| 5 — SC-08 | No `kubernetes.io` dir; API call fails | `ls: cannot access '/var/run/secrets/kubernetes.io': No such file or directory` exit=2; `urlopen('https://kubernetes.default.svc')` exit=1 | PASS |
| 6 — SC-03 pods | `1` and `1` | `1` and `1` | PASS |
| 6 — SC-03 claims | Both denied, correct messages | `spec.branch in body should match '^agent/[a-z0-9][a-z0-9._/-]{0,100}$'`; `an AgentRun is named xplane-run-<runId>, runId being 8 characters of [a-z2-7]` | PASS |
| 7 — R7 | `Failed PodFailed`; old SA NotFound; new run Running on `$BRANCH` | `xplane-run-6qnowwxl`: `BRANCH=agent/6qnowwxl`; `Failed PodFailed`; `serviceaccounts "xplane-run-6qnowwxl" not found`; `xplane-run-peiuqflu` Running, `spec=agent/6qnowwxl status=agent/6qnowwxl` | PASS |
| Cleanup | `No resources found` | `6qnowwxl`: `No resources found`. `peiuqflu`: CNP, pod (`Terminating`) and Usage still present right after `delete --wait` returned, which is the SC-07 ordering at work. All three were gone by the final sweep (see runbook 07, SC-14) | PASS |

Round 7 notes: the runbook's "Idle. Do nothing" task now finishes in about a minute (`x5hf55tr` `Succeeded` after 106 s), so runs that must stay up used `Run 'sleep N' in the terminal …`.

### Earlier rounds — aws-0

| Step | Expected | Observed | Pass/Fail |
|---|---|---|---|
| 1 — platform up | All `Ready=True`; XRD `True`; `yes` | All 6 Kustomizations `Ready=True`; XRD `Established=True`; `can-i` = `yes` | PASS |
| 2 — Q1 timing | Node Ready ≤ pod start; small `FailedCreatePodSandBox` count | Node Ready `23:44:45Z`, pod start `23:44:50Z` (5s after); submission-to-Running 178s; `FailedCreatePodSandBox` count `0` | PASS |
| 3 — SC-01 | `gvisor`/`gvisor`/gVisor banner/`Seccomp: 0` | `gvisor ip-10-0-23-81...`; node label `gvisor`; `Starting gVisor...`; `Seccomp:\t0` | PASS |
| 4 — SC-02 | `release-20260921.0`; v3 plugin id; `oci-seccomp = "false"` | `runsc version release-20260921.0`; `io.containerd.cri.v1.runtime`/runsc, `ConfigPath = '/etc/containerd/runsc.toml'`; `oci-seccomp = "false"` | PASS |
| 5 — SC-08 | No `kubernetes.io` dir; API call fails | `ls: cannot access ... No such file or directory` exit=2; `socket.gaierror: ... Temporary failure in name resolution` exit=1 | PASS |
| 6 — SC-03 pods | `1` and `1` | `1` and `1` (each pod also independently denied by `agents-pod-creator`, since the caller isn't the sandbox controller SA) | PASS |
| 6 — SC-03 claims | Both denied, correct messages | `spec.branch ... should match '^agent/...'` (schema pattern, not CEL — see correction above); `an AgentRun is named xplane-run-<runId>...` (XRD CEL) | PASS |
| 7 — R7 | `Failed PodFailed`; old SA NotFound; new run Running on `$BRANCH` | `xplane-run-rfguy2pm`: `BRANCH=agent/rfguy2pm`; `Failed PodFailed`; `serviceaccounts "xplane-run-rfguy2pm" not found`; `xplane-run-wimjedrr` Running with spec/status branch `agent/rfguy2pm agent/rfguy2pm` | PASS |
| Cleanup | `No resources found` | `No resources found` (sa/cm/cnp/sandbox/pod/usages) | PASS |
