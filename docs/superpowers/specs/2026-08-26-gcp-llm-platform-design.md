# GPU and the LLM platform on GCP — workstream 14

**Date:** 2026-08-26
**Status:** approved, not yet implemented
**Workstream:** 14 of the [GCP support programme](2026-08-18-gcp-support-design.md) — the last one
**ADR:** [ADR-0021](../../../website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)

## Problem

The self-hosted LLM platform runs on `aws-0` behind two independent gates and is not portable. Its
eight Flux children under `clusters/aws-0-llm-platform/` assume AWS in three specific places: model
weights come from an Amazon S3 Files POSIX mount ([ADR-0004](../../../website/content/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md)),
the preload Job's identity is an `EPI`, and GPU capacity comes from a Karpenter NodePool.

## What is already done

Checked against the repository, not assumed:

- **GPU capacity exists.** `infrastructure/gcp-0/computeclass/gpu-l4.yaml` provisions `g2` machines
  with one `nvidia-l4` on spot, delivered by workstream 4. There is no GCP equivalent of
  `infrastructure-gpu-nodepools` to write.
- **Most of the stack is already cloud-agnostic.** The programme design's verified list covers Envoy
  Gateway, Envoy AI Gateway, VictoriaMetrics/Logs/Traces, KEDA and vLLM/`InferenceService`.
- **`runtimeclass-nvidia` has no GCP counterpart, and this is a positive fact rather than an
  omission.** Its own comment explains it exists because Bottlerocket's NVIDIA AMI advertises
  `nvidia.com/gpu` through kubelet and crashloops the upstream device plugin, so AWS ships the
  RuntimeClass alone. GKE installs and manages GPU drivers itself. Nothing to port.

So the umbrella on `gcp-0` is **six children, not eight**.

## The decision this workstream turns on

`aws-0` mounts weights from **Amazon S3 Files** — one resource that satisfies all four of ADR-0004's
requirements at once: durable across cluster rebuilds, fast enough for vLLM to `mmap` `.safetensors`
inside a 90-second cold-start budget, shared across replicas, and retained on claim deletion.

**GCP has no single equivalent**, and that is the crux. The two candidates split those properties:

| | Cloud Storage FUSE | Hyperdisk ML |
|---|---|---|
| Durability across teardown | bucket survives; storage cost only | volume survives, and **bills continuously while it does** |
| Cold start | FUSE — the path ADR-0004 rated weaker | *"up to 11.9×"* faster than loading from a registry |
| Shared across replicas | yes | yes, `ReadOnlyMany` |
| Setup per deploy | none | **hydration**: Job → RWO disk → convert to ROM |
| Constraints | — | zonal only; `g2` is supported, verified |

**Chosen: Cloud Storage FUSE.** The reasoning and the rejected alternatives are in
[ADR-0021](../../../website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md).

The short version: this platform is torn down after every test, and its standing constraint is that
nothing bills afterwards. A Hyperdisk ML volume kept between tests violates that directly; hydrating
one per deploy pays a populate step every time. A bucket costs storage alone and survives teardown
exactly as `aws-0`'s S3 bucket does.

**The cost is real and is stated rather than argued away.** ADR-0004 rejected FUSE for AWS on
per-pod overhead and throughput limits. That reasoning does not evaporate on GCP. What changes is
which requirement binds: the 90-second budget is a serving-platform SLO for `aws-0`, and `gcp-0` is a
demonstration platform that exists for minutes at a time. If cold start proves unacceptable when
measured, Hyperdisk ML is the documented escape hatch and nothing else in this design has to change.

## Design

### Model weights

A GCS bucket holds the weights, mounted into vLLM pods by GKE's managed Cloud Storage FUSE CSI
driver. The preload Job writes to it once; serving pods read.

**The bucket name takes the project prefix, not the region prefix.** `aws-0` uses
`${region}-ogenki-llm-models`. Copying that shape to GCP fails: the Crossplane principal's storage
role is conditioned on `resource.name.startsWith('projects/_/buckets/<project_id>-ogenki-')`
(`opentofu/gcp/gke/init/iam.tf`), so a region-prefixed bucket is refused at create with a 403 naming
`storage.buckets.create` — a permission the role *does* hold, which is why the error points nowhere
near the condition that rejected it. Workstream 9 hit exactly this on a live cluster; the lesson is
already paid for.

### Identity

The preload Job's write access is a `GCPWorkloadIdentity` with `bucketRoles`, replacing the AWS
`EPI`. Bucket-scoped, never project-scoped: a project-level `roles/storage.*` would reach OpenBao's
snapshot bucket and CNPG's backups, which is the reason `bucketRoles` exists in the composition.

Serving pods need read; the preload Job needs write. Whether that is one identity or two is an
implementation decision for the plan, but the grant must not be wider than the pod that holds it.

### The umbrella

`clusters/gcp-0-llm-platform/` mirrors `clusters/aws-0-llm-platform/`, gated the same way: an
umbrella Kustomization at `clusters/gcp-0/llm-platform.yaml` with `spec.suspend: true`, kept a
sibling of `clusters/gcp-0/` so `flux-system`'s recursive sync cannot apply the children and bypass
the suspend. Six children:

| Child | Status on GCP |
|---|---|
| `apps-llm` | **new work** — GCS bucket, FUSE mount, WI instead of EPI |
| `security-llm-wi` | **new work** — `GCPWorkloadIdentity` replacing the preload `EPI` |
| `infrastructure-envoy-gateway` | port as-is, already cloud-agnostic |
| `infrastructure-envoy-ai-gateway` | port as-is |
| `infrastructure-vllm-semantic-router` | port as-is |
| `tooling-promptfoo` | port as-is |
| ~~`infrastructure-gpu-nodepools`~~ | **not needed** — ComputeClass already exists |
| ~~`infrastructure-runtimeclass-nvidia`~~ | **not needed** — GKE manages GPU drivers |

### A prerequisite to verify, not assume

The Cloud Storage FUSE CSI driver is a GKE addon and must be enabled on the cluster. The exact
variable on `terraform-google-modules/kubernetes-engine` could not be confirmed from this worktree —
`.terraform/` is gitignored and absent until `tofu init`. **The plan's first step is to confirm the
variable name against the vendored module**, not to write a name from memory. Getting this wrong
produces a cluster where every FUSE mount hangs with no obvious cause.

## Success criteria

1. A GCS bucket named `<project_id>-ogenki-llm-models` is created by Crossplane and reaches
   `SYNCED=True READY=True` — the project prefix proven against the IAM condition, not assumed.
2. The preload identity is bucket-scoped: its composed `BucketIAMMember` names one bucket, and the
   claim requests no project-level `roles:`.
3. `aws-0`'s rendered output is unchanged. Verified by bundle diff.
4. The gcp-0 umbrella is `suspend: true`, and `flux-system`'s recursive sync does not apply the
   children.
5. `check-substitution.py` passes — any new `${var}` exists in **both** clusters' ConfigMaps, or is
   applied only from a path one cluster owns. This gate did not exist for workstreams 9 or 13; it
   does now, and it is the reason this workstream should not repeat their variable omissions.
6. Cold start is **measured, not asserted**, if and when the platform is deployed. Until then, no
   claim is made about whether FUSE meets the 90-second budget.

## Out of scope

- Deploying the platform. Both gates ship closed, exactly as `aws-0`'s do; enabling costs GPU spend
  and is a separate decision.
- Changing `aws-0`. ADR-0004 stands; nothing here revisits S3 Files.
- Hyperdisk ML. Documented in ADR-0021 as the escape hatch, not built.
