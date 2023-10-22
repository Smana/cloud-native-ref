# AWS permissions for Crossplane
module "iam_assumable_role_crossplane" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.21.0"
  role_name = "${var.cluster_name}-crossplane"

  assume_role_condition_test = "StringLike"

  role_policy_arns = {
    irsa = aws_iam_policy.crossplane_irsa.arn,
    s3   = aws_iam_policy.crossplane_s3.arn
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
  name        = "crossplane_irsa_policy_${var.cluster_name}"
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
  name        = "crossplane_s3_policy_${var.cluster_name}"
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
                "arn:aws:s3:::${var.region}-ogenki-loki/*"
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
                "arn:aws:s3:::${var.region}-ogenki-loki/*"
            ]
        }
    ]
}
EOF
}
