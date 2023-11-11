# AWS permissions for the EBS-CSI-DRIVER
module "irsa_ebs_csi_driver" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.21.0"
  role_name = "${var.cluster_name}-ebs_csi_driver"

  assume_role_condition_test = "StringLike"

  role_policy_arns = {
    policy = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-*"]
    }
  }
}


# AWS permissions for Crossplane
module "irsa_crossplane" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.21.0"
  role_name = "${var.cluster_name}-crossplane"

  assume_role_condition_test = "StringLike"

  role_policy_arns = {
    cloudwatch = aws_iam_policy.crossplane_cloudwatch.arn,
    kinesis    = aws_iam_policy.crossplane_kinesis.arn,
    firehose   = aws_iam_policy.crossplane_firehose.arn,
    irsa       = aws_iam_policy.crossplane_irsa.arn,
    s3         = aws_iam_policy.crossplane_s3.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["crossplane-system:provider-aws-*"]
    }
  }
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_irsa" {
  name        = "crossplane_irsa_${var.cluster_name}"
  path        = "/"
  description = "Policy for creating IRSA on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "iam:TagPolicy",
                "iam:TagRole",
                "iam:CreateRole",
                "iam:CreatePolicy",
                "iam:PutRolePolicy",
                "iam:DeletePolicy",
                "iam:DeleteRole",
                "iam:DetachRolePolicy",
                "iam:AttachRolePolicy",
                "iam:UpdateAssumeRolePolicy",
                "iam:PassRole"
            ],
            "Resource": [
                "arn:aws:iam::*:role/xplane-*",
                "arn:aws:iam::*:policy/xplane-*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "iam:Get*",
                "iam:List*"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_s3" {
  name        = "crossplane_s3_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing S3 Buckets on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "s3:*",
            "Resource": [
                "arn:aws:s3:::${var.region}-ogenki-loki",
                "arn:aws:s3:::${var.region}-ogenki-loki/*",
                "arn:aws:s3:::${var.region}-ogenki-vector-stream",
                "arn:aws:s3:::${var.region}-ogenki-vector-stream/*"
            ]
        },
        {
            "Effect": "Deny",
            "Action": [
                "s3:DeleteBucket",
                "s3:DeleteObject",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::${var.region}-ogenki-loki",
                "arn:aws:s3:::${var.region}-ogenki-loki/*",
                "arn:aws:s3:::${var.region}-ogenki-vector-stream",
                "arn:aws:s3:::${var.region}-ogenki-vector-stream/*"
            ]
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_cloudwatch" {
  name        = "crossplane_cloudwatch_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing Log groups and streams on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:PutRetentionPolicy",
                "logs:TagResource"
            ],
            "Resource": [
              "arn:aws:logs:*:*:log-group:xplane-*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:FilterLogEvents",
                "logs:GetLogEvents",
                "logs:ListTagsLogGroup"
            ],
            "Resource": "arn:aws:logs:*"
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_firehose" {
  name        = "crossplane_firehose_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing Firehose DeliveryStreams on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "firehose:CreateDeliveryStream",
                "firehose:DescribeDeliveryStream",
                "firehose:ListDeliveryStreams",
                "firehose:PutRecord",
                "firehose:PutRecordBatch",
                "firehose:UpdateDestination",
                "firehose:StartDeliveryStreamEncryption",
                "firehose:StopDeliveryStreamEncryption",
                "firehose:TagDeliveryStream",
                "firehose:UntagDeliveryStream",
                "firehose:DescribeDeliveryStreamEncryption",
                "firehose:PutDestination",
                "firehose:Get*",
                "firehose:List*"
            ],
            "Resource": "arn:aws:firehose:*:*:deliverystream/xplane-*"
        }
    ]
}
EOF
}


#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_kinesis" {
  name        = "crossplane_kinesis_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing Kinesis on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kinesis:Describe*",
                "kinesis:List*",
                "kinesis:Get*"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}
