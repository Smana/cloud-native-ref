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

# Cluster-internal bootstrap resources and the data sources that feed them
# (aws_eks_cluster_auth, secretsmanager approle/github-app, gateway-API CRDs,
# route53 zone) were moved to eks/configure. They require a live cluster, which
# does not exist during this cluster-creating apply — keeping a kubectl provider
# configured from module.eks.* outputs here broke fresh applies.

# Karpenter manifests moved to Flux GitOps (infrastructure/base/karpenter/)
