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

All live under `*/base/`, so they are shared between clusters. `gp3` is **not defined in this
repository** — EKS's EBS CSI driver provides it. GKE provides `standard-rwo`, `balanced-rwo` and
`premium-rwo` instead. A PVC asking for `gp3` on `gcp-0` binds to nothing and stays `Pending`
forever, with no error naming the cause.

Nothing breaks today only because `gcp-0` deploys just its own overlays — no observability, apps or
tooling. This is therefore the right moment to fix it: the pattern lands before the workstreams that
would trip over it, rather than as eight emergency edits during one of them.

## Decision

| Decision | Outcome |
|---|---|
| Mechanism | A `${storage_class}` postBuild variable, per cluster |
| `aws-0` value | `gp3` (unchanged behaviour) |
| `gcp-0` value | `balanced-rwo` — pd-balanced, the honest `gp3` equivalent |
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
storage_class = "balanced-rwo"
```

```yaml
storageClassName: ${storage_class}
```

### Why a shared variable is honest here, when `${region}` was not

Workstream 8 removed `region: ${region}` from a claim precisely because it was a shared key whose
**shape** differed per cloud: an AWS-region-shaped field receiving `europe-west4`, fed to the AWS
SDK, breaking an STS call. The lesson recorded there was that one name behind two differently-shaped
values is the defect, not the sharing itself.

A storage class name does not have that problem. On both clouds it is a string naming a class the
cluster provides, consumed by the same Kubernetes field, interpreted by nothing else. `gp3` and
`balanced-rwo` are different *values* of the same *kind of thing* — which is exactly what a
postBuild variable is for.

The test to apply to any future shared key: **does anything downstream interpret this value as more
than an opaque string?** For `region`, yes — the AWS SDK derived an endpoint from it. For
`storage_class`, no.

### Why `balanced-rwo`

`gp3` is SSD-backed. `balanced-rwo` maps to pd-balanced, also SSD, and is the honest equivalent.
`standard-rwo` (pd-standard, HDD) is cheaper and was considered given this platform's
tear-down-after-every-run posture, but the largest consumer is a VictoriaMetrics cluster whose write
path is I/O-sensitive; a storage class chosen to save pennies on a throwaway cluster would make its
behaviour there unrepresentative of production, which is the opposite of what a reference platform
is for.

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

1. Every affected manifest renders `gp3` in `aws-0`'s bundle and `balanced-rwo` in `gcp-0`'s.
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
