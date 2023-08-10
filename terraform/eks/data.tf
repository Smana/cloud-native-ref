data "aws_caller_identity" "this" {}

data "aws_availability_zones" "available" {}

#tflint-ignore: terraform_unused_declarations
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.virginia
}

data "aws_eks_cluster_auth" "cluster_auth" {
  name = module.eks.cluster_name
}

data "http" "gateway_api_crds" {
  count = length(local.gateway_api_crds_urls)
  url   = local.gateway_api_crds_urls[count.index]
}
