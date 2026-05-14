# LLM Platform — S3 Files

S3 Files filesystem + IAM bootstrap for the self-hosted LLM platform's model
weights. **Interim** until Crossplane Upbound `provider-upjet-aws` v2.6+ ships
the `s3files.aws.m.upbound.io` CRDs (verified absent in v2.5.0, May 2026).
Once available, `T020f` migrates these resources to native managed resources
without requiring a composition rewrite.

## What this stack provisions

| Resource | Purpose |
|----------|---------|
| `aws_iam_role.s3files_service` | Service role assumed by `elasticfilesystem.amazonaws.com` to read/write the underlying S3 bucket |
| `aws_iam_role.csi_driver` | Pod-side role for the EFS CSI driver (EKS Pod Identity) — grants `s3files:ClientMount/ClientWrite` |
| `aws_security_group.mount_targets` | Allows NFS 2049/TCP from EKS worker-node SG |
| `aws_s3files_file_system.models` | The S3 Files filesystem layered on the existing `eu-west-3-ogenki-llm-models` bucket |
| `aws_s3files_mount_target.az[*]` | One mount target per private-subnet AZ |
| `aws_s3files_access_point.shared` | Single shared access point at `/models`, POSIX UID/GID 1001 (matches vLLM container) |
| `aws_s3files_file_system_policy.models` | Restricts mount to the CSI driver role |

## Prerequisites

- `network` and `eks/init` stacks applied (for VPC, private subnets, node SG)
- The bucket `eu-west-3-ogenki-llm-models` exists with versioning enabled
  (S3 Files requires versioning — verified at apply time). Bucket name is
  region-prefixed because S3 names are globally unique; the constitution's
  `xplane-*` naming convention is enforced on Crossplane-managed *resource
  names* (XR, MR, Composition), not on AWS-side bucket names.

## IAM scope exception

The `s3files_service` role grants `s3:DeleteObject` on the model bucket —
required for NFS unlink semantics (a mounted pod's `rm <file>` must
propagate to S3). This is an intentional exception to the platform
constitution's "no deletion permissions for stateful services" rule.
Mitigations: the Crossplane Bucket MR's `managementPolicies` excludes
Delete (the bucket itself cannot be removed) and bucket versioning is on
(object DELETE writes a delete-marker, prior versions remain
restorable). See `iam.tf` preamble for full details.

## Apply

This stack is **opt-in** under Terramate orchestration (tag `opt-in` + env-var-gated `deploy`/`preview`/`drift`/`destroy` scripts in `workflows.tm.hcl`). The default `terramate script run deploy` from `opentofu/` will print `[skip]` and move on, leaving sibling stacks untouched.

```bash
# Direct (no orchestration):
cd opentofu/llm-platform
tofu init
tofu plan -var-file=variables.tfvars
tofu apply -var-file=variables.tfvars

# Via Terramate (opt-in):
TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/llm-platform script run deploy

# As part of a full deploy:
TM_LLM_PLATFORM_ENABLED=true terramate script run deploy

# CI / audit — exclude this stack entirely without setting any env var:
terramate script run --no-tags=opt-in deploy
```

Outputs:

```bash
tofu output volume_handle
# → "s3files:fs-xxxxxxxx::fsap-xxxxxxxx" — paste into the InferenceService
#   composition's PV (or the Crossplane EnvironmentConfig at
#   clusters/mycluster-0/environment-config.yaml).
```

## Wiring into the GitOps tree

After apply, copy the outputs into:

1. `clusters/mycluster-0/environment-config.yaml` — the `llm` block:
   ```yaml
   llm:
     fsId: <filesystem_id>
     accessPointId: <access_point_id>
     volumeHandle: <volume_handle>
     csiDriverRoleArn: <csi_driver_role_arn>
   ```
2. `infrastructure/base/aws-efs-csi/helmrelease.yaml` — the EFS CSI driver
   reads the role via EKS Pod Identity (no values change needed if the EPI
   composition already wires `csiDriverRoleArn`).

The `xinferenceservices` composition reads `fsId` + `accessPointId` from the
EnvironmentConfig and renders a static PV per claim with subPath isolation
under `/<claim-name>/`.

## Migration to Crossplane (T020f)

When Upbound publishes `s3files.aws.m.upbound.io/v1beta1` CRDs:

1. Add the resources to `infrastructure/base/crossplane/providers/activation-policy.yaml`.
2. Re-render the same resources as managed resources under
   `infrastructure/base/llm-models-fs/` (or as a Crossplane composition).
3. Remove this stack — the EnvironmentConfig keys stay the same.
4. Run `tofu state rm` then `tofu destroy` to delete the OpenTofu-tracked
   resources without disturbing the (now Crossplane-tracked) AWS state.
