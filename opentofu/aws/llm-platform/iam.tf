# IAM scope notes — read before editing this file.
#
# 1. `s3files_bucket_access` (below) grants the S3 Files service role
#    `s3:DeleteObject` and `s3:DeleteObjectVersion` on the model
#    bucket. This is functionally required for NFS unlink semantics
#    (mounted pods rm a file → S3 must propagate the delete) and is
#    therefore an intentional exception to the platform constitution
#    rule "no deletion permissions for stateful services". The
#    rule's intent — protecting against accidental data loss — is
#    preserved at two upstream layers:
#      - The Crossplane Bucket MR uses
#        `managementPolicies: ["Observe","Create","Update","LateInitialize"]`
#        (apps/base/ai/llm/s3-bucket.yaml) so Crossplane will not
#        delete the bucket itself, even if the XR is deleted.
#      - The bucket has versioning enabled (also enforced at create
#        time by S3 Files), so DELETE on an object only writes a
#        delete-marker and the prior version can be restored.
#    Object-level delete = OK; bucket-level delete = forbidden.
#
# 2. The `csi_driver` role (further below) attaches AWS-managed
#    policies (AmazonEFSCSIDriverPolicy + AmazonS3FilesCSIDriverPolicy)
#    that include unscoped `Resource: "*"` actions. Resource scoping
#    happens at the file-system policy layer
#    (filesystem.tf::aws_s3files_file_system_policy.models), which
#    only permits the csi_driver role to mount this filesystem. This
#    sidesteps the AWS-managed policy's wildcard without re-rolling
#    a custom policy.
#
# IAM role assumed by the S3 Files service itself to access the underlying
# S3 bucket. The trust principal is `elasticfilesystem.amazonaws.com` —
# `s3files.amazonaws.com` does NOT exist (CreateRole fails with
# MalformedPolicyDocument). Source-arn condition scopes the trust to
# filesystems in this account only.
resource "aws_iam_role" "s3files_service" {
  name = "${var.filesystem_name}-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "elasticfilesystem.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:s3files:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:file-system/*" }
      }
    }]
  })

  tags = var.tags
}

# Bucket access for the S3 Files service. Includes the multipart-upload +
# versioning permissions required for two-way sync between NFS clients and
# S3 API writers.
resource "aws_iam_role_policy" "s3files_bucket_access" {
  name = "${var.filesystem_name}-bucket-access"
  role = aws_iam_role.s3files_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetObjectTagging",
        "s3:GetObjectVersionTagging",
        "s3:PutObject",
        "s3:PutObjectTagging",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
      ]
      Resource = [data.aws_s3_bucket.models.arn, "${data.aws_s3_bucket.models.arn}/*"]
    }]
  })
}

# EventBridge: required for S3-side writes (e.g., manual `aws s3 cp` to the
# bucket) to propagate to NFS clients. Without these, writes via S3 API are
# invisible to mounted pods until the next FS scan.
resource "aws_iam_role_policy" "s3files_eventbridge" {
  name = "${var.filesystem_name}-eventbridge"
  role = aws_iam_role.s3files_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "events:PutRule",
        "events:PutTargets",
        "events:DeleteRule",
        "events:DisableRule",
        "events:EnableRule",
        "events:RemoveTargets",
      ]
      Resource = "arn:aws:events:*:*:rule/DO-NOT-DELETE-S3-Files*"
      Condition = {
        StringEquals = { "events:ManagedBy" = "elasticfilesystem.amazonaws.com" }
      }
    }]
  })
}

# Permissions boundary for the CSI driver role. The AWS-managed policies
# attached below grant unscoped (`Resource: "*"`) access to the EFS and
# S3 Files APIs — a future filesystem in this account that lacks its
# own filesystem policy could be mounted by this role unless we trim
# at the boundary. The boundary acts as an upper bound: even if the
# managed policy says yes, IAM denies anything outside this allow-list.
#
# The carve-out for `*`-resource actions (ec2:DescribeAvailabilityZones,
# elasticfilesystem:Describe*) is required: those API calls don't
# support resource-level permissions and would otherwise be denied,
# breaking CSI mount discovery.
resource "aws_iam_policy" "csi_driver_boundary" {
  name        = "${var.filesystem_name}-csi-driver-boundary"
  description = "Permissions boundary scoping the EFS CSI driver role to this filesystem only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeOnlyApis"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "elasticfilesystem:DescribeFileSystems",
          "elasticfilesystem:DescribeMountTargets",
          "elasticfilesystem:DescribeAccessPoints",
        ]
        Resource = "*"
      },
      {
        Sid    = "FilesystemScopedActions"
        Effect = "Allow"
        Action = [
          "elasticfilesystem:CreateAccessPoint",
          "elasticfilesystem:DeleteAccessPoint",
          "elasticfilesystem:TagResource",
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess",
          "s3files:ClientMount",
          "s3files:ClientWrite",
          "s3files:ClientRootAccess",
        ]
        Resource = [
          aws_s3files_file_system.models.arn,
          "${aws_s3files_file_system.models.arn}/*",
        ]
      },
    ]
  })

  tags = var.tags
}

# IAM role consumed by the EFS CSI driver controller pod via EKS Pod
# Identity. This role grants client-side mount + write on the access point;
# the file-system policy below restricts which roles may mount, and the
# permissions boundary above caps what the role can do even if its
# attached policies are broader.
resource "aws_iam_role" "csi_driver" {
  name                 = "${var.filesystem_name}-csi-driver"
  permissions_boundary = aws_iam_policy.csi_driver_boundary.arn

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

# Use the AWS-managed policies recommended by the EFS CSI driver docs
# (chart v4.x / driver v3.0+). Covers both EFS and S3 Files mount paths
# without per-FS scoping — restriction lives in the file_system_policy
# (only this role may mount the FS) AND in the permissions boundary
# above (the role itself can't escape this filesystem's ARN).
resource "aws_iam_role_policy_attachment" "csi_driver_efs" {
  role       = aws_iam_role.csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "csi_driver_s3files" {
  role       = aws_iam_role.csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonS3FilesCSIDriverPolicy"
}

# Bind both EFS CSI driver SAs to the csi_driver IAM role via EKS Pod
# Identity:
#   - efs-csi-controller-sa: deployment that handles volume lifecycle
#   - efs-csi-node-sa: DaemonSet that performs the actual NFS mount
#     (without IAM the s3files mount fails with 'access denied by server')
# The SAs are created by the chart; PIAs can be created before the SA
# exists (EKS stores them and applies on SA creation).
resource "aws_eks_pod_identity_association" "csi_controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-controller-sa"
  role_arn        = aws_iam_role.csi_driver.arn

  tags = var.tags
}

resource "aws_eks_pod_identity_association" "csi_node" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "efs-csi-node-sa"
  role_arn        = aws_iam_role.csi_driver.arn

  tags = var.tags
}
