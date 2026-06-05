data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_caller_identity" "this" {}

# Re-derived here (rather than read from eks/init remote state) to keep this
# stage self-contained. Same tag filters as the VPC created by opentofu/network.
data "aws_vpc" "selected" {
  filter {
    name   = "tag:project"
    values = ["cloud-native-ref"]
  }
  filter {
    name   = "tag:owner"
    values = ["Smana"]
  }
  filter {
    name   = "tag:environment"
    values = [var.env]
  }
}

data "aws_route53_zone" "public" {
  name         = var.public_domain_name
  private_zone = false
}

# OIDC provider ARN for the cluster IRSA/EPI issuer — re-derived from the
# cluster's OIDC issuer URL instead of reading module.eks output via remote state.
data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_secretsmanager_secret_version" "github_app" {
  secret_id = var.github_app_secret_name
}

data "aws_secretsmanager_secret_version" "cert_manager_approle" {
  secret_id = var.cert_manager_approle_secret_name
}

data "http" "gateway_api_crds" {
  count = length(local.gateway_api_crds_urls)
  url   = local.gateway_api_crds_urls[count.index]
}
