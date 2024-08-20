# AWS permissions for the EBS-CSI-DRIVER
module "irsa_ebs_csi_driver" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.44.0"
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
  version   = "5.44.0"
  role_name = "${var.cluster_name}-crossplane"

  assume_role_condition_test = "StringLike"

  role_policy_arns = {
    ec2  = aws_iam_policy.crossplane_ec2.arn,
    eks  = aws_iam_policy.crossplane_eks.arn,
    irsa = aws_iam_policy.crossplane_irsa.arn,
    kms  = aws_iam_policy.crossplane_kms.arn,
    rds  = aws_iam_policy.crossplane_rds.arn
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

# Managing all the security groups can be a security issue, didn't find a way to restrict to the ones created by Crossplane so far
#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_ec2" {
  name        = "crossplane_ec2_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing Security Groups on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AuthorizeSecurityGroupEgress",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:CreateSecurityGroup",
                "ec2:DeleteSecurityGroup",
                "ec2:DescribeSecurityGroups",
                "ec2:DescribeSecurityGroupRules",
                "ec2:RevokeSecurityGroupEgress",
                "ec2:RevokeSecurityGroupIngress",
                "ec2:ModifySecurityGroupRules",
                "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
                "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
                "ec2:CreateTags"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_eks" {
  name        = "crossplane_eks_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing EKS Pod identities"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribePodIdentityAssociation",
                "eks:CreatePodIdentityAssociation",
                "eks:DeletePodIdentityAssociation",
                "eks:TagResource"
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
                "arn:aws:s3:::${var.region}-ogenki-harbor",
                "arn:aws:s3:::${var.region}-ogenki-harbor/*",
                "arn:aws:s3:::${var.region}-ogenki-loki",
                "arn:aws:s3:::${var.region}-ogenki-loki/*",
                "arn:aws:s3:::${var.region}-ogenki-vault-snapshot",
                "arn:aws:s3:::${var.region}-ogenki-vault-snapshot/*"
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
                "arn:aws:s3:::${var.region}-ogenki-harbor",
                "arn:aws:s3:::${var.region}-ogenki-harbor/*",
                "arn:aws:s3:::${var.region}-ogenki-loki",
                "arn:aws:s3:::${var.region}-ogenki-loki/*",
                "arn:aws:s3:::${var.region}-ogenki-vault-snapshot",
                "arn:aws:s3:::${var.region}-ogenki-vault-snapshot/*"
            ]
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_rds" {
  name        = "crossplane_rds_${var.cluster_name}"
  path        = "/"
  description = "Policy for managing RDS Instances on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "rds:*"
            ],
            "Resource": [
                "arn:aws:rds:*:*:db:xplane-*",
                "arn:aws:rds:*:*:subgrp:xplane-*"
            ]
        },
        {
            "Action": [
                "rds:DescribeDBInstances"
            ],
            "Effect": "Allow",
            "Resource": [
                "arn:aws:rds:*:*:db:*",
                "arn:aws:rds:*:*:subgrp:*"
            ]
        },
        {
            "Effect": "Deny",
            "Action": [
                "rds:DeleteDBInstance"
            ],
            "Resource": [
                "arn:aws:rds:*:*:db:*",
                "arn:aws:rds:*:*:subgrp:*"
            ]
        }
    ]
}
EOF
}

#tfsec:ignore:aws-iam-no-policy-wildcards
resource "aws_iam_policy" "crossplane_kms" {
  name        = "crossplane_kms_${var.cluster_name}"
  path        = "/"
  description = "Policy for creating KMS keys on EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:Get*",
                "kms:ListAliases",
                "kms:DescribeKey",
                "kms:ListResourceTags"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                    "kms:CreateKey",
                    "kms:TagResource",
                    "kms:CreateAlias"
            ],
            "Resource": [
                "*"
            ],
            "Condition": {
                "StringLike": {
                    "aws:RequestTag/crossplane-name": "xplane-*"
                }
            }
        }
    ]
}
EOF
}
