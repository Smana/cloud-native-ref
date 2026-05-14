resource "aws_security_group" "mount_targets" {
  # checkov:skip=CKV2_AWS_5:SG is attached via aws_s3files_mount_target.az.security_groups (line ~47). Checkov doesn't recognize the newer aws_s3files_mount_target resource, so it emits a false positive — the SG is not orphaned.
  name        = "${var.filesystem_name}-mount-targets"
  description = "Allow NFS (2049/TCP) from EKS worker nodes to S3 Files mount targets."
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  tags = merge(var.tags, { Name = "${var.filesystem_name}-mount-targets" })
}

resource "aws_security_group_rule" "mount_targets_nfs_in" {
  type                     = "ingress"
  description              = "NFS from EKS worker-node security group"
  protocol                 = "tcp"
  from_port                = 2049
  to_port                  = 2049
  source_security_group_id = data.aws_security_group.eks_nodes.id
  security_group_id        = aws_security_group.mount_targets.id
}

resource "aws_s3files_file_system" "models" {
  bucket   = data.aws_s3_bucket.models.arn
  role_arn = aws_iam_role.s3files_service.arn

  # `accept_bucket_warning` acknowledges that S3 Files needs versioning
  # (already on for this bucket — the composition enables it). Without
  # this flag the API returns a warning and we'd have to set it manually
  # on subsequent applies.
  accept_bucket_warning = true

  tags = merge(var.tags, { Name = var.filesystem_name })

  # First-create takes a few minutes; mount-targets creation pings the
  # filesystem until READY.
  timeouts {
    create = "15m"
    delete = "15m"
  }
}

# One mount target per AZ where EKS worker nodes run. Pods on a node use
# the mount target in the same AZ — cross-AZ NFS is allowed but adds
# latency + data-transfer cost.
resource "aws_s3files_mount_target" "az" {
  count           = length(data.terraform_remote_state.network.outputs.private_subnets)
  file_system_id  = aws_s3files_file_system.models.id
  subnet_id       = data.terraform_remote_state.network.outputs.private_subnets[count.index]
  security_groups = [aws_security_group.mount_targets.id]
}

# Mount targets need ~2-3 min to reach `available`. Give the access point
# resource a chance to find them.
resource "time_sleep" "wait_for_mount_targets" {
  depends_on      = [aws_s3files_mount_target.az]
  create_duration = "120s"
}

# Single shared access point at `/models`. All InferenceService claims
# share this access point, with per-claim subPath isolation handled by
# the kubelet at mount time (claim name = subPath under /models).
# Per-claim access points with scoped root_directory.path are an
# option later if per-model RBAC needs to be tightened.
resource "aws_s3files_access_point" "shared" {
  file_system_id = aws_s3files_file_system.models.id

  posix_user {
    # Match the InferenceService composition's pod securityContext
    # (runAsUser/runAsGroup/fsGroup = 1001 — see kcl/inference-service/main.k).
    uid = 1001
    gid = 1001
  }

  # Use a sub-tree (`/models`) instead of `/` so the access point can own
  # and chmod the root dir. With path=/ the FS root keeps its initial
  # 0755 root:root and kubelet's subPath mkdir fails with EACCES (NFS
  # sees posix_user=1001 trying to write under a 1001-unwritable parent).
  root_directory {
    path = "/models"
    creation_permissions {
      owner_uid   = 1001
      owner_gid   = 1001
      permissions = "0775"
    }
  }

  tags = merge(var.tags, { Name = "${var.filesystem_name}-shared" })

  depends_on = [time_sleep.wait_for_mount_targets]
}

# Restrict mount to the CSI driver role. The driver pod uses EKS Pod
# Identity → assumes csi_driver role → mounts the access point on behalf
# of any application pod that references the PV.
resource "aws_s3files_file_system_policy" "models" {
  file_system_id = aws_s3files_file_system.models.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.csi_driver.arn }
      Action    = ["s3files:ClientMount", "s3files:ClientWrite"]
      Resource  = aws_s3files_file_system.models.arn
    }]
  })
}
