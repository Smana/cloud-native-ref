# Live gates on gcp-0 — 2026-09-30

Round 7 of the agent-factory runbooks, plus the GCP parity plan's platform gates (Task 8.3) and the gVisor
smoke probe (Task 8.5). The cluster is `gke_ogenki-435905_europe-west4-a_gcp-0`, tracking
`integration/agent-factory` @ `a2c645ba`, the first deploy after the reset (a RESTORE of
`2026-09-13T214920Z-gcpckms.snap`). The runbooks' own results tables hold the round-7 rows; this file holds
the plan's evidence, which has no runbook to live in.

**Verdict.** The agent platform works on gcp-0. SC-04 passes: issue #2140 became PR #2141 through the whole
chain, with the GKE-issued token accepted by `agent-router` and by octo-sts. Three defects remain open,
F1 to F3 below.

| # | Finding | Where it shows | Severity |
|---|---|---|---|
| F1 | The OpenBao snapshot job cannot upload: `roles/storage.objectCreator` lacks `storage.objects.get`, which `gcloud storage cp` needs | 8.3 Steps 9, 10 | No scheduled snapshot on gcp-0 |
| F2 | cilium-operator deletes run pods that landed on a fresh gVisor node before the Cilium agent was ready. A run already `Running` is lost (R7) | 8.5 Step 2, runbook 01 Step 2 | Intermittent run failure on scale-up, plus a short window with no network policy |
| F3 | `agents-gvisor` (`e2-standard-8`) cannot scale while the project's `CPUS_ALL_REGIONS` quota stands at 26/32. NAP falls back to `e2-standard-4` | 8.5 Step 2 | A `large` run (4 vCPU) cannot fit the fallback |

## Task 8.3 — platform gates

| Step | Result | Evidence |
|---|---|---|
| 1 — break-glass login | [OWNER] | Needs the admin password from Secret Manager piped into `bao login`. This session holds no OpenBao token by design |
| 2 — mounts, policies, `oidc/` | [OWNER] | Needs a token |
| 3 — migrate the platform keys | [OWNER] | `secret-store.sh migrate` writes through `bao kv`, so it needs a token. Indirect evidence that the keys are there: every `openbao-platform` ExternalSecret is synced (Step 4), `zai-api-key` included (Step 4a) |
| 4 — force-sync, ES and KS | PASS | Force-synced at `2026-09-30T19:52:36Z`: 32 ExternalSecrets, 0 not Ready. 42 Kustomizations: every unsuspended one `Ready`. The only suspended one is `llm-platform`, which Ruling AB keeps suspended on purpose |
| 4a — the frontier route's key | PASS | `True SecretSynced` |
| 5 — no store reads AWS | PASS | `1 gcpsm`, `3 vault` |
| 6 — capability probes | [OWNER] | `bao write auth/jwt/gcp-0/login …` mints a token |
| 7 — ZITADEL is fresh | PASS | `\|ogenki-435905-ogenki-cnpg-backups`; `Password SecretSynced`; `1` ready replica; ConfigMap `393085211987935508 https://auth.gcp.cloud.ogenki.io` = Secret Manager `393085211987935508` |
| 8 — public DNS for the IdP | PASS | `35.204.52.220`; `1`; `True`; `grafana.priv.gcp.ogenki.io` → `100.105.59.59` |
| 9 — a scheduled snapshot works | **FAIL** (F1) | `xplane-openbao-snapshot` `Ready=True`. The job ran `openbao-snapshot-probe` and failed 3 of 3 pods: `ERROR: (gcloud.storage.cp) HTTPError 403: Caller does not have storage.objects.get access to the Google Cloud Storage object … objects/2026-09-30T195339Z-gcpckms.snap`. No object was written (`gcloud storage ls … \| grep 2026-09-30` returns nothing). The probe job is deleted |
| 10a — CNPG archiving | PASS | `apps/xplane-image-gallery-cnpg-cluster`, `security/xplane-zitadel-cnpg-cluster`, `tooling/xplane-harbor-cnpg-cluster`: `True Continuous archiving is working`. Ruling Z3's `toCIDR` holds |
| 10b — snapshot `lastSuccessfulTime` | **FAIL** (F1) | Empty. The CronJob was created at `18:22:15Z`, after today's `0 4 * * *`, so it has not fired yet. Step 9 shows it will fail the same way |

### F1 — the snapshot job's bucket role is one permission short

**Root cause.** `security/gcp-0/openbao-snapshot/workloadidentity.yaml` grants only
`roles/storage.objectCreator` on `ogenki-435905-ogenki-openbao-snapshot`, on the reasoning that "`save()` does
one `gcloud storage cp` and nothing else". But `gcloud storage cp` also asks for `storage.objects.get` on the
destination object: the 403 names that permission on the object being uploaded. `objectCreator` holds only
`storage.objects.create`. So the copy fails before it writes anything, and it is not a network problem:
the 403 comes from the Storage API. The
bucket's IAM confirms the binding:
`principal://…/subject/ns/security/sa/openbao-snapshot` → `roles/storage.objectCreator`.

**Proposed fix.** Add a second `bucketRoles` entry, `roles/storage.objectViewer` (`objects.get` and
`objects.list`, still no `delete`), to the same claim. It is already on terraform's
`crossplane_bucket_grantable_roles` (`opentofu/gcp/gke/init/iam.tf`), so no terraform change is needed.
Correct the comment's claim about `cp`. Then re-run 8.3 Step 9.

## Task 8.5 — the gVisor smoke probe

| Step | Result | Evidence |
|---|---|---|
| 1 — GKE's RuntimeClass | PASS | `gvisor {"sandbox.gke.io/runtime":"gvisor"}` |
| 2 — the probe, from zero | PASS on the second attempt | Second attempt: `pod/gvisor-smoke condition met`; `threads=4 dns=ok tcp=ok release=4.4.0`; node `gke-gcp-0-nap-e2-standard-4-eu44yfye-f40fbfde-75h6`, `runtime=gvisor`. First attempt, from zero: `TriggeredScaleUp … agents-gvisor … 0->1`, the pod reached `Succeeded` (`kubectl wait` → `condition met`), then cilium-operator deleted it: `Restarting unmanaged pod … timeSincePodStarted=31.05s k8sPodName=gvisor-smoke/gvisor-smoke`. That took its log with it (F2). The second attempt's `agents-gvisor` scale-up failed with `FailedScaleUp … GCE quota exceeded` (F3), and NAP provisioned a gVisor `e2-standard-4` node instead |
| 2a — the negative Gateway check | PASS | A pod whose CNP allows only kube-dns, `curl -sS -m 10 https://auth.gcp.cloud.ogenki.io` (40 s after the CNP), from the zitadel node (`…-1smjy8jv-4eed7f34-dq4z`): `000`, `curl: (35) Recv failure: Connection reset by peer`. From another node (`gke-gcp-0-static-b60a3466-rltt`): the same. On both nodes Hubble shows `-> security/cilium-gateway-zitadel:443 (host) to-proxy FORWARDED`, then `<- … (TCP Flags: ACK, RST)`: Envoy takes the connection and refuses it (`EnforcePolicyOnL7Lb`). No policy hole. The namespace is deleted |
| 3 — clean up, and back to zero | See below | `namespace "gvisor-smoke" deleted` at `20:11:41Z`. The pool check waited until every run of the round was gone |

### F2 — run pods land before Cilium, and cilium-operator deletes them

**Root cause.** The `agents-gvisor` pool and NAP nodes carry `node.cilium.io/agent-not-ready`, and Ruling
Z1's Kyverno mutate (`security/gcp-0/sandbox-policies/gvisor-cilium-toleration.yaml`) makes every gVisor pod
tolerate it, so that GKE's autoscaler will scale the pool from zero (ADR-0006). The toleration is not scoped to
the autoscaler's simulation, though, so the scheduler also binds the pod to the new node before the Cilium
agent is ready. The pod then starts without a CiliumEndpoint, which means no CNP applies to it for that
window. cilium-operator's `unmanaged-pods-gc` later restarts it:

```
msg="Restarting unmanaged pod" … timeSincePodStarted=2m2.148692445s k8sPodName=agents/xplane-run-j2qh5avm
```

It did this to the smoke probe and to six of the ten run pods created in this round, every one that landed
on a node a few minutes old. A pod the Sandbox still reports `Pending` is recreated and the run carries on
(`4iv2rpdq`, `x5hf55tr`, `6qnowwxl`, `x6jexfi4`). A run already `Running` latches `Failed PodFailed` by design
(R7, F2b): `j2qh5avm` and `pttpamhs` were lost this way. aws-0 is not
affected, because Karpenter ignores startup taints in its simulation, so its pods never need the toleration.

**Proposed fix, to be decided by the owner.** In order of preference:
1. Stop tolerating the taint at runtime. Give Cilium an agent-not-ready taint key that GKE's cluster
   autoscaler ignores in its simulation (`agentNotReadyTaintKey`, using the autoscaler's
   `ignore-taint.cluster-autoscaler.kubernetes.io/` or `startup-taint.cluster-autoscaler.kubernetes.io/`
   prefix), then drop the Z1 mutate. Whether GKE's managed autoscaler honours these prefixes has not been
   checked yet. Check it with the smoke probe from zero first.
2. If it does not honour them: keep the toleration for the autoscaler, but hold the pod until Cilium is
   up. For example, a `schedulingGates` entry that a small controller removes once the node has lost the
   taint, or a composition-level retry that treats a pod deleted by cilium-operator as not yet started.
3. Mitigate only: reduce the window by keeping one warm gVisor node (the pool minimum at 1). That costs one
   spot `e2-standard-8`, and it does not close the no-policy window on a second node.

### F3 — the CPU quota blocks the sandbox pool's machine type

**Root cause.** `agents-gvisor` is `e2-standard-8`, spot, 0–2 nodes (GP-10). The project's global
`CPUS_ALL_REGIONS` quota is 32, and gcp-0 already uses 26 vCPU, so an 8-vCPU node cannot start:
`FailedScaleUp … Node scale up in zones europe-west4-a associated with this pod failed: GCE quota exceeded`.
NAP then provisions a 4-vCPU `nap-e2-standard-4-*` gVisor node, which serves `small` runs (1 vCPU requested).
A `large` run requests 4 vCPU, above an `e2-standard-4`'s ~3.9 allocatable, so it would stay Pending. The
first scale-up of the day did succeed (node `gke-gcp-0-agents-gvisor-0166ac85-plzh`), before the NAP nodes had
taken the headroom.

**Proposed fix.** Ask for a `CPUS_ALL_REGIONS` increase to at least 48, which covers two sandbox nodes on top
of the platform. Or record the NAP fallback as expected on gcp-0, and cap AgentRun `size` at `medium` there.

## Task 8.6 — the agent gates

| Step | Result | Evidence |
|---|---|---|
| 3 — G-0 is on `main` | PASS | `1` (#2122 merged 2026-09-29) |
| 4 — runbooks 01 to 08 | See the runbooks' round-7 tables | Summary in the README's status table. SC-04: `xplane-run-4iv2rpdq` took issue #2140 to PR #2141, pod on `gke-gcp-0-agents-gvisor-0166ac85-plzh` (`sandbox.gke.io/runtime=gvisor`), with `agent-router` `:8080` `200` ×10 and `:8082` (sts) `200` ×1 for its `x_ar_agent` |

## Runbook corrections found this round

Not applied to the runbook text here; each is also noted in its runbook's round-7 table.

| Runbook | Correction |
|---|---|
| all | `curl https://vl.priv.gcp.ogenki.io/…` needs `--cacert opentofu/gcp/openbao/management/.tls/ca.pem`. Without it, curl under `-s` prints nothing |
| all | An "Idle. Do nothing" task now finishes in about a minute. A run that must stay up needs a paced task, such as `Run 'sleep N' in the terminal …` |
| 01 | Still AWS-shaped. Step 1 lists `agents-nodepool` and `runtimeclass-gvisor`, which do not exist on gcp-0. Step 3 reads `agents.ogenki.io/runtime`, where gcp-0 has `sandbox.gke.io/runtime`. Step 4 targets Karpenter/AL2023's `runsc` install and needs a GKE Sandbox equivalent |
| 04 | B.1: the Secret's key is `promptfoo`, not `promptfoo_apikey`. B.3: the frontier model is `glm-5.3`. B.6: wait about 60 s after applying the probe BTP, and change the rule, not just the header value, for a fresh bucket |
| 05 | A reviewer run needs `--task-url <PR>`. `--task` text is refused by the XRD |
| 06 | Step 5: `kubectl auth can-i get pods/log` checks a pod named `log`. Use `kubectl auth can-i get pods --subresource=log` |
| 07 | Step 1's grep counts `1` against a placeholder (`ghcr.io/smana/agent-harness:v0.1.0@sha256:...`), not the real pin. The live pin is `v0.1.0-pr2110.29b5f228@sha256:3cc93e00…` |
