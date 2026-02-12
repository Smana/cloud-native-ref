data "aws_caller_identity" "this" {}
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
    values = ["dev"]
  }
}
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.region}-${var.env}-private-*"]
  }
}
data "aws_subnets" "intra" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.region}-${var.env}-intra-*"]
  }
}

data "aws_security_group" "tailscale" {
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
  filter {
    name   = "tag:app"
    values = ["tailscale"]
  }
}

#tflint-ignore: terraform_unused_declarations
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

data "aws_eks_cluster_auth" "cluster_auth" {
  name = module.eks.cluster_name
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

data "aws_route53_zone" "public" {
  name         = var.public_domain_name
  private_zone = false
}

# Karpenter manifests moved to Flux GitOps (infrastructure/base/karpenter/)
