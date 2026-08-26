# Portable storage classes — workstream 13

**Status:** design approved 2026-08-26, not yet implemented.

Makes every PVC in this repo name a storage class the cluster actually has, so a manifest under
`*/base/` renders correctly on `aws-0` and `gcp-0` alike. Also **removes Filestore from this
workstream's scope**, with the reasoning recorded below.

## The problem

Eight manifests hardcode `storageClassName: gp3`:

| File | |
|---|---|
| `observability/base/victoria-metrics-k8s-stack/helmrelease-vmcluster.yaml` | ×2 |
| `observability/base/victoria-traces/helmrelease-vtsingle.yaml` | |
| `observability/base/grafana-oncall/helmrelease-rabbitmq.yaml` | |
| `observability/base/runlore/helmrelease.yaml` | |
| `infrastructure/base/vllm-semantic-router/helmrelease.yaml` | |
| `apps/base/openwebui/pvc.yaml` | |
| `tooling/base/gha-runners/default-scale-set-helmrelease.yaml` | |

All live under `*/base/`, so they are shared between clusters. **This repository creates the `gp3`
StorageClass object** — `kubectl_manifest.gp3_storageclass` in
`opentofu/aws/eks/configure/kubernetes.tf:128`, `provisioner: ebs.csi.aws.com`, annotated
`storageclass.kubernetes.io/is-default-class: "true"`. EKS's EBS CSI managed add-on supplies the
*provisioner*; the *class* — the named object a PVC actually binds against — is ours. GKE's Compute
Engine persistent disk CSI driver auto-installs three classes instead: `standard` (in-tree
`kubernetes.io/gce-pd`, pd-standard, HDD), `standard-rwo` (**pd-balanced**, SSD), and `premium-rwo`
(pd-ssd). **There is no `balanced-rwo`** — an earlier draft of this document invented that name by
misreading GKE's naming (see "Why `standard-rwo`" below for the correction and its evidence). A PVC
asking for `gp3` on `gcp-0` binds to nothing and stays `Pending` forever, with no error naming the
cause.

**Consequence this creates, one layer down: `gcp-0` has no `kubectl_manifest`-style resource for
`standard-rwo` either, and does not need one.** `opentofu/gcp/gke/configure/` publishes the *name*
via the `storage_class` ConfigMap key; the class itself is one of the three GKE auto-installs with
its PD CSI driver, the same way `standard-rwo` and `premium-rwo` need no OpenTofu resource anywhere
else in this repository today. This is corroborated in-repo, not merely assumed:
`opentofu/gcp/gke/init/helm_values/flux-instance.yaml:6` already sets `gcp-0`'s own Flux artifact PVC
to `storage.class: standard-rwo`, carried through a `gcp-0` cluster that deployed successfully. That
is a different Helm value on a different resource than the eight manifests this workstream changes,
so it does not by itself prove those eight will render and bind — both clusters are currently
destroyed, so **this workstream's own eight sites remain unverified by a live render or a bound
PVC, to confirm on the next `gcp-0` deploy** with `kubectl get storageclass` and
`kubectl get pvc -o wide`. If GKE ever stops auto-installing `standard-rwo`, every PVC on `gcp-0`
stays `Pending` — the exact failure this workstream exists to prevent, one layer down from where
this workstream fixed it.

**A related asymmetry this plan does not touch, but should be on record.** The AWS class above is
marked *default* (`is-default-class: "true"`); on `gcp-0` — GKE **Standard**, per ADR-0005, not
Autopilot — the class carrying the default annotation is the legacy in-tree class literally named
`standard` (provisioner `kubernetes.io/gce-pd`, pd-standard, HDD), not `standard-rwo`. `standard-rwo`
is pre-installed alongside it (see above), but Google marks it default only on **Autopilot**
clusters, which this repo does not run. As with the `standard-rwo`-exists corroboration above, both
clusters are currently destroyed, so this specific fact is a documented expectation rather than an
observed one — to confirm on the next `gcp-0` deploy with `kubectl get storageclass`. This has no
effect on the eight sites in this workstream — every one of them names `storageClassName` explicitly,
so neither cluster's default is ever consulted.

It matters for something already in this repository, not a hypothetical: **five PVC-shaped
resources already omit `storageClassName` and take whichever default each cluster provides.** They
were out of scope for this workstream because they don't hardcode a name that fails to exist on the
other cloud — they already degrade gracefully to *some* class, which is a different problem than the
eight sites that named one that doesn't exist at all on `gcp-0`.

| Consumer | Where |
|---|---|
| `vmsingle` | `observability/base/victoria-metrics-k8s-stack/helmrelease-vmsingle.yaml` — `storage:` block, no class |
| `victoria-logs` single server | `StatefulSet.volumeClaimTemplates/server-volume` |
| `harbor-jobservice` | PVC, `tooling` |
| `harbor-trivy` | `StatefulSet.volumeClaimTemplates/data` |
| `oncall-grafana` | PVC (component not currently wired into any Kustomization) |

The first one is the sharpest example, because it inverts the "Why `standard-rwo`" rationale below:
the VictoriaMetrics deployment actually running today is `vmsingle`, not the `vmcluster` that
rationale is about — `vmcluster` sits in the same directory, fully valued, but commented out of
`kustomization.yaml`. `vmsingle` names no class, so on `gcp-0` it would land on `standard`/pd-standard
/HDD regardless of what `${storage_class}` resolves to. The SSD choice below protects a write path
that, as actually configured today, would not use it.

None of this is a deploy-breaker — like the eight sites this workstream does change, none of these
five are deployed to `gcp-0` today (`gcp-0` runs none of `observability/`, `apps/` or `tooling/` yet;
see below). It is left as a recorded gap rather than a ninth-through-thirteenth call site: giving
these five an explicit
`storageClassName: ${storage_class}` would change their AWS behaviour too (they currently take
`aws-0`'s default, which happens to be `gp3` — the same value — but that is a coincidence of AWS's
default, not a guarantee), which is a larger, separately-reviewable change this workstream did not
set out to make.

Nothing breaks today only because `gcp-0` deploys just its own overlays — no observability, apps or
tooling. This is therefore the right moment to fix it: the pattern lands before the workstreams that
would trip over it, rather than as eight emergency edits during one of them.

## Decision

| Decision | Outcome |
|---|---|
| Mechanism | A `${storage_class}` postBuild variable, per cluster |
| `aws-0` value | `gp3` (unchanged behaviour) |
| `gcp-0` value | `standard-rwo` — pd-balanced, the honest `gp3` equivalent (not the HDD tier the name suggests) |
| Filestore | **Dropped from this workstream.** See below. |
| Karpenter `volumeType: gp3` | Untouched — not a storage class |

## The mechanism

Each cluster's `configure` stack already publishes a vars ConfigMap consumed via
`postBuild.substituteFrom` — `eks-aws-0-vars` and `gke-gcp-0-vars`. Every Kustomization that applies
the affected manifests already declares that block; verified on `apps`, `tooling` and
`observability`. So this adds one key to each ConfigMap and changes eight values. No new plumbing.

```yaml
# opentofu/aws/eks/configure/kubernetes.tf
storage_class = "gp3"
# opentofu/gcp/gke/configure/kubernetes.tf
storage_class = "standard-rwo"
```

```yaml
storageClassName: ${storage_class}
```

### Deploy ordering on a cluster that already exists

The eight manifests need the `storage_class` ConfigMap key to exist before Flux reconciles them.
Flux sets no strict-substitution feature gate on either `FluxInstance` — the only feature gate
either one sets is `CancelHealthCheckOnNewRevision` — so a Kustomization referencing an undefined
`postBuild` variable does not fail; the variable substitutes to **empty**, and
`storageClassName: ${storage_class}` renders as `storageClassName:` with nothing after the colon.
Reproduced by re-rendering the bundle with `FIXTURE_VARS["storage_class"]` set to `""`: both
`victoria-traces` (`vtsingle`) and `runlore` — the two of the eight sites actually wired into a live
Kustomization on `aws-0` today, the other six being commented out, unwired, or under the suspended
`llm-platform` umbrella — are inside `StatefulSet.volumeClaimTemplates`, which is immutable after
creation. An empty `storageClassName` there fails the `HelmRelease` upgrade with
`updates to statefulset spec ... are forbidden`, not a `Pending` PVC.

Harmless on a fresh cluster build, where `opentofu/*/configure` always runs before Flux ever
reconciles anything. **Not harmless if this branch is merged onto a cluster that already exists and
is already running Flux: apply `opentofu/aws/eks/configure` (to publish the ConfigMap key) before
merging**, so Flux never reconciles the new manifest content against an `aws-0` that hasn't
published `storage_class` yet.

### Why a shared variable is honest here, when `${region}` was not

Workstream 8 removed `region: ${region}` from a claim precisely because it was a shared key whose
**shape** differed per cloud: an AWS-region-shaped field receiving `europe-west4`, fed to the AWS
SDK, breaking an STS call. The lesson recorded there was that one name behind two differently-shaped
values is the defect, not the sharing itself.

A storage class name does not have that problem. On both clouds it is a string naming a class the
cluster provides, consumed by the same Kubernetes field, interpreted by nothing else. `gp3` and
`standard-rwo` are different *values* of the same *kind of thing* — which is exactly what a
postBuild variable is for.

The test to apply to any future shared key: **does anything downstream interpret this value as more
than an opaque string?** For `region`, yes — the AWS SDK derived an endpoint from it. For
`storage_class`, no.

### Why `standard-rwo`

`gp3` is SSD-backed. `standard-rwo` maps to pd-**balanced**, also SSD, and is the honest equivalent
— despite the name, it is not GKE's HDD tier. That is `standard` (pd-standard, HDD, in-tree
`kubernetes.io/gce-pd`), which is cheaper and was considered given this platform's
tear-down-after-every-run posture, but rejected: the largest consumer is a VictoriaMetrics cluster
whose write path is I/O-sensitive; a storage class chosen to save pennies on a throwaway cluster
would make its behaviour there unrepresentative of production, which is the opposite of what a
reference platform is for. (An earlier draft of this section had the two names' disk types swapped —
`standard-rwo` believed to be the HDD tier and rejected on that belief, `balanced-rwo` invented as
the SSD tier that does not exist. See "The problem" above for the correction and its evidence:
`opentofu/gcp/gke/init/helm_values/flux-instance.yaml` already runs `standard-rwo` successfully.)

### The fixture is not optional

`scripts/flux-schema/render-bundle.py` must gain a `storage_class` entry in `FIXTURE_VARS`. Without
it, `VAR_RE.sub` passes the name through and the bundle renders a literal `${storage_class}` — which
**passes schema validation**, because `storageClassName` is a free-form string. This is the same
blind spot recorded in workstream 8: a missing fixture is invisible to the gate.

## What is deliberately not touched

`volumeType: gp3` in `infrastructure/base/karpenter-nodepools/default-ec2nc.yaml` (×2) and
`karpenter-nodepools-gpu/gpu-l4-ec2nc.yaml`. That field is an EC2 **node root-volume type** inside a
Karpenter `EC2NodeClass` — AWS-only by construction, on a resource GKE does not have. GKE uses
`ComputeClass` (ADR-0006). Substituting a variable there would be a category error: the string
happens to match, the meaning does not.

## Filestore, removed from scope

Workstream 13 as written says *"EFS CSI → Filestore CSI"*. Workstream 14 says the LLM platform uses
*"GCS Fuse weights"*. Those contradict, and resolving it removes work rather than adding it.

The EFS StorageClass has exactly **one** consumer — `apps/base/ai/llm/models-pvc.yaml` — and it does
not provision anything dynamically. It is a statically-bound PV naming a specific AWS filesystem:

```yaml
csi:
  driver: efs.csi.aws.com
  volumeHandle: s3files:fs-09c78abe09076e43e::fsap-08c1a3dc6971a7bff
```

So if the weights go to GCS Fuse on GCP, **Filestore would have no consumer at all** — an unused CSI
driver installed on every GCP cluster, which someone later has to reason about and be afraid to
remove.

GCS Fuse is the right answer for this workload on its merits:

1. **Cost.** Filestore bills on *provisioned* capacity with a **1 TiB floor** — an instance below
   1 TiB still consumes 1 TiB of quota, and 100 GiB stored in a 1 TiB instance is billed as 1 TiB.
   Per-GB it runs roughly 10× Cloud Storage Standard. On clusters torn down after every run, that is
   the most expensive thing this platform could add.
2. **Access pattern.** Model weights are write-once (a preload Job fetches them) and read-many (vLLM
   loads at startup). No shared writes, no file locking — which is precisely where Filestore starts
   earning its premium, and a line this workload never crosses.
3. **Parity.** The existing class is `s3files-llm-models` with a `s3files:` volume handle: the AWS
   side is **already object-storage-backed**. Fuse keeps both clouds on "objects mounted as files";
   Filestore would make GCP the outlier running real managed NFS.
4. **Identity reuse.** GCS Fuse authenticates through Workload Identity, which workstream 8 built,
   shipped and verified live including bucket-scoped `roles/storage.objectAdmin` grants. A Fuse mount
   reuses `GCPWorkloadIdentity.bucketRoles` directly. Filestore reuses none of it.

**Known risk, for workstream 14 to verify:** Cloud Storage FUSE offers approximate POSIX semantics.
If vLLM requires `mmap` on weight files or real file locking, Fuse will disappoint. That must be
tested against the actual GPU workload rather than assumed — it is the one thing that would reopen
this decision.

`infrastructure/base/aws-efs-csi-driver/` stays exactly as it is; it serves `aws-0` and this
workstream does not touch it.

## Success criteria

1. Every affected manifest renders `gp3` in `aws-0`'s bundle and `standard-rwo` in `gcp-0`'s.
2. `./scripts/validate-manifests.sh` passes with `Invalid: 0, Skipped: 0`.
3. `python3 scripts/flux-schema/check-substitution.py` passes — every `${storage_class}` sits under a
   Kustomization declaring `postBuild`.
4. Removing the `storage_class` entry from `FIXTURE_VARS` makes a gate **fail**. If it does not, the
   coverage is theatre and the fixture blind spot survives.
5. The GCP design doc records that Filestore was dropped and why, so it is not re-added from the
   roadmap table.
6. No change to what `aws-0` renders: the bundle diff for AWS is the substitution only.

## Out of scope

- GCS Fuse itself — workstream 14, driven by the GPU workload that exercises it.
- Hyperdisk. The roadmap mentions it alongside pd-balanced; it is a newer, faster family with its own
  machine-type constraints, and nothing here needs that performance. Adding it would be speculative.
- Per-tier storage classes (`fast`/`standard`). All eight consumers use one class today; splitting
  the variable before a consumer needs a different tier would be inventing a requirement.
