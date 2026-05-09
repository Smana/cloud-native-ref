## ADR-0004: Use Amazon S3 Files for LLM Model Weights Storage

**Status**: Accepted
**Date**: 2026-05-01
**Deciders**: Smana (Platform Owner)
**Related Spec**: [Self-Hosted LLM Platform with Cascade Routing](../plans/self-hosted-llm-platform/02-spec-draft.md)
**Supersedes (in part)**: implementation of spec FR-011 + plan T013/T019 — replaces "init-container `aws s3 sync` + `emptyDir` staging" with a POSIX mount of an S3 Files file system over the same bucket. The bucket and EPI ratification (CL-8) stand.

**TL;DR**: Mount the model-weights S3 bucket via **Amazon S3 Files** (Option 4); bootstrap the FileSystem via OpenTofu until Upbound `provider-upjet-aws` v2.6+ ships native CRDs. Drop the init-container, drop the `emptyDir`, drop the platform-wide xvdb 80 GiB.

---

## Context

The self-hosted LLM platform stores four open-weights model checkpoints (Phi-4 Mini ~4 GB, Qwen3-8B ~16 GB, DeepSeek-R1-Distill-Qwen3-8B ~16 GB, LlamaGuard 3-1B ~2.5 GB) in a private model registry. The weights need to be:

1. **Durable across cluster lifecycle** — clusters are rebuilt; preload from HuggingFace (~15 min/model + Meta access wait for LlamaGuard) must not repeat per cluster.
2. **Read-fast at vLLM startup** — vLLM `mmap`s the `.safetensors` file at boot; cold-start budget is 90 s per FR-005.
3. **Shared across replicas** — KEDA scales pod count up to `maxReplicas`; replicas load the same file.
4. **Retained on claim deletion** — per ADR-0002, IAM/S3 resources are not auto-deleted with claims.

The original spec chose **S3 bucket + init-container `aws s3 sync` + local `emptyDir`**. The pattern surfaced four problems on first deploy:

- **Cold-start budget regression** — S3 → node sync adds ~90 s on top of image pull, approaching the 90 s budget.
- **Disk-pressure eviction** — default Karpenter nodes ship ~18 GiB allocatable; 16 GiB models trigger kubelet disk-pressure eviction. The xvdb 80 GiB workaround leaks model size into platform-wide node sizing.
- **Wasted bytes** — every replica copies the same 16 GiB to its own `emptyDir`; the preload Job holds another copy during HF→S3 transit.
- **Source-of-truth duplication** — S3 is already durable, scalable, and shared; copying to a node-local FS to read it back gives those properties up.

**Amazon S3 Files** (AWS, April 2026, GA in 34 regions including `eu-west-3`): a managed POSIX file system over an S3 bucket, built on EFS technology, with multi-TB/s aggregate read throughput. The same primitive that's needed.

---

## Decision Drivers

- **Cluster ephemerality** — model weights must survive cluster recreation without re-preload.
- **Cold-start budget** (90 s, FR-005) — eliminate the local-copy step.
- **Storage simplicity** — single source-of-truth, no per-replica copies.
- **GitOps alignment** — declarative through Crossplane / Flux.
- **Failure-mode reduction** — disk-pressure mitigation should not be platform-wide overhead for one Job class.
- **Operational pre-existence** — bucket already managed via Crossplane; favour incremental change.

---

## Considered Options

| # | Option | Verdict | Pros | Cons |
|---|--------|---------|------|------|
| 1 | **Status quo** — S3 + init-container `aws s3 sync` + `emptyDir` | Rejected | Already partly implemented; no new dependency | Cold-start regression; disk-pressure eviction; wasted bytes; preload needs ~32 GiB scratch |
| 2 | **[Mountpoint for Amazon S3](https://github.com/awslabs/mountpoint-s3-csi-driver)** (CSI) | Rollback target | GA today; POSIX reads; vLLM `mmap` works; standard PVC shape | FUSE userspace gateway = per-pod overhead; append-only writes (preload still needs scratch); per-pod throughput limited |
| 3 | **JuiceFS / s3fs / goofys** | Rejected | Cloud-agnostic | JuiceFS needs a metadata service (stateful dep); s3fs / goofys = FUSE per-pod; cloud-native-ref is AWS-only by design (ADR-0001/0002/0003) |
| 4 | **Amazon S3 Files** (April 2026, EFS-on-S3) | **Chosen** | No local copy (vLLM `mmap`s direct off the mount); no node-disk sizing tied to model size; shared across replicas (page cache); fits EKS Pod Identity (FileSystem-attached IAM role); Cilium egress narrows back to a tight FQDN list (no Xet CDN — see [[cilium-fqdn-egress-gotchas]]) | Brand-new; Upbound `provider-upjet-aws@v2.5.0` does not yet ship CRDs (Terraform AWS provider has the resource — Upbound auto-generation lag 2-6 weeks); per-file `mmap` latency on safetensors not yet documented; AWS-only |

---

## Decision Outcome

**Chosen**: **Option 4 (Amazon S3 Files)**, with a bootstrap that bridges Crossplane CRD availability:

- **Today (until Upbound `provider-upjet-aws` v2.6+)**: provision `FileSystem` + `AccessPoint` + IAM role via OpenTofu in a new stack `opentofu/llm-platform/`. Outputs propagate to the cluster via the existing `eks-environment` Crossplane `EnvironmentConfig`.
- **InferenceService composition** consumes `option("params").ctx["apiextensions.crossplane.io/environment"].llm.fsId` and renders a `PersistentVolumeClaim` against an S3 Files-backed `StorageClass`.
- **Drop** the init-container `aws s3 sync`. Drop the per-Deployment `models` `emptyDir`. Drop the preload Job's `tmp` `emptyDir`. Mount the same PVC at `/models/<repo>/<revision>/` in both pods.
- **Drop** the platform-wide xvdb 80 GiB on `default-ec2nc.yaml`.
- **Migrate to native Crossplane CRDs** when Upbound v2.6+ ships them — composition consumer side stays unchanged (still reads FS ID from EnvironmentConfig).

**Rationale**: Aligns with the cluster-ephemeral / S3-as-durable intent. Eliminates all four staging-pattern problems in one move. The OpenTofu interim is consistent with how Network/OpenBao/EKS already bootstrap; migration to native CRDs is a swap with zero composition change.

---

## Consequences

### Positive

- **Cold-start budget**: drops from `Karpenter (~30 s) + image pull (~60 s) + S3 sync (~90 s)` ≈ 180 s to `Karpenter (~30 s) + image pull (~60 s)` ≈ 90 s, leaving headroom under FR-005. Image pull becomes the new optimization target (EBS snapshot pre-bake of `vllm/vllm-openai:v0.6.5` — out of scope for this ADR).
- **No disk-pressure failure mode**: default nodes don't need oversized data volumes; node sizing decouples from model size.
- **Durable model registry**: cluster recreation reuses the existing FileSystem.
- **Egress narrows**: preload Job's HF Xet CDN egress goes away; tight `huggingface.co` API allowlist returns. Default-deny + explicit allow stays intact.
- **Replica scaling free of weight-copy overhead**: KEDA 1→3 is gated on Karpenter + image pull only.

### Negative

- **Brand-new AWS service**: limited operational track record. Mitigation: validate per-file `mmap` latency on a fresh deploy with one model before committing the platform; the S3 bucket remains the durable layer underneath, so an S3 Files outage doesn't lose data.
- **Interim OpenTofu dependency**: one resource on the platform-bootstrap path. Mitigation: small surface, explicit migration plan to native Crossplane on v2.6+.
- **AWS lock-in**: cloud-native-ref is AWS-only by design (ADR-0001/0002/0003); this ADR doesn't change the portability story but forecloses moving the registry to GCS/Azure without falling back to Option 2/3.

### Neutral

- **Cilium egress policy**: returns to a tight FQDN allowlist on the preload Job (`huggingface.co` API only).
- **Plan revision**: Phase 4 splits into 4a (S3 base) + 4b (S3 Files via OpenTofu); T013 (init-container) and T019 (preload Job emptyDir) shrink.

---

## Implementation Notes

### Order of operations

1. **OpenTofu stack** `opentofu/llm-platform/` — `aws_s3files_file_system.llm_models` over the existing bucket; `aws_s3files_access_point` (one shared by default); IAM role `xplane-llm-models-fs-access` with the EKS Pod Identity Agent trust policy. Outputs: `llm_models_fs_id`, `llm_models_fs_dns_name`, `llm_models_fs_role_arn`.
2. **EnvironmentConfig refresh** `clusters/mycluster-0/environment-config.yaml` — fold the OpenTofu outputs alongside `clusterName` / `region`.
3. **CSI driver install** — once AWS publishes the K8s integration (TBD: extension of `efs-csi-driver` or a dedicated `s3files-csi-driver`); HelmRelease under `infrastructure/base/`, dependency-ordered after `crossplane-providers`.
4. **InferenceService composition update** — `weightsBucket` → `weightsFileSystem`; drop init-container; drop `models` `emptyDir`; render PVC referencing the new `StorageClass`.
5. **Cilium egress** — drop the temporary `toEntities: world` on TCP 443 once preload no longer hits the HF Xet CDN; replace with a tight `huggingface.co` API allowlist.
6. **Migrate** to Crossplane MRs when Upbound v2.6+ publishes `FileSystem.s3files.aws.m.upbound.io` etc. — composition consumer side unchanged.

### Validation gates

- Cold-start P95 on a freshly-provisioned `gpu-l4` node with one model warm-loading ≤ 90 s (FR-005 / SC-001).
- IAM scope: `aws iam simulate-principal-policy` on the FileSystem-attached role allows S3 Files read, denies write (extends T020).
- Disk-pressure regression: deploy 4 InferenceService claims simultaneously, 0 evictions on default nodes.
- Multi-replica: scale a model 1→3, replicas 2 and 3 reach `Ready` faster than replica 1 (shared mount cache).

### Rollback

If S3 Files latency under safetensors `mmap` proves problematic, revert to **Option 2 (Mountpoint for Amazon S3 CSI)** — same composition shape, different `StorageClass`. The status-quo init-container path is also recoverable from this branch's git history but is no longer the preferred fallback (Option 2 keeps the per-pod-copy elimination win).

---

## References

- [Amazon S3 Files announcement (April 2026)](https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-s3-files/)
- [InfoQ: AWS S3 Files](https://www.infoq.com/news/2026/04/aws-s3-files/)
- [Terraform AWS provider — `internal/service/s3files/file_system.go`](https://github.com/hashicorp/terraform-provider-aws/blob/main/internal/service/s3files/file_system.go)
- [Mountpoint for Amazon S3 CSI driver](https://github.com/awslabs/mountpoint-s3-csi-driver) — Option 2 / rollback target
- ADR-0002: [Use EKS Pod Identity over IRSA](0002-eks-pod-identity-over-irsa.md)
- ADR-0003: [Use vLLM Production Stack over KServe + llm-d](0003-vllm-production-stack-over-kserve.md)
- Spec: [Self-Hosted LLM Platform with Cascade Routing](../plans/self-hosted-llm-platform/02-spec-draft.md) — this ADR supersedes the implementation of FR-011 only
- Plan: [03-plan-draft.md](../plans/self-hosted-llm-platform/03-plan-draft.md) — Phase 4 split
- Clarifications: [04-clarifications-draft.md](../plans/self-hosted-llm-platform/04-clarifications-draft.md) — CL-8 (storage layer, ratified) + CL-9 (mount mechanism, this ADR)
