# AWS permissions for Crossplane
module "iam_assumable_role_crossplane" {
  source    = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version   = "5.21.0"
  role_name = "${var.cluster_name}-crossplane"

  assume_role_condition_test = "StringLike"

  role_policy_arns = {
    policy = aws_iam_policy.crossplane_irsa.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["system:serviceaccount:crossplane-system:crossplane*"]
    }
  }
}

resource "aws_iam_policy" "crossplane_irsa" {
  name        = "crossplane_irsa_policy_${var.cluster_name}"
  path        = "/"
  description = "Policy for creating IRSA on AWS EKS"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "iam:CreateRole",
                "iam:CreatePolicy",
                "iam:AttachRolePolicy",
                "iam:PassRole"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}
