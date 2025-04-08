provider "aws" {
  region = var.region
}

provider "vault" {
  address         = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
  token           = jsondecode(data.aws_secretsmanager_secret_version.openbao_root_token_secret.secret_string)["token"]
  namespace       = "openbao"
  skip_tls_verify = true
}

data "aws_secretsmanager_secret_version" "openbao_root_token_secret" {
  secret_id = var.openbao_root_token_secret_id
}

data "aws_eks_cluster" "cluster" {
  name = var.eks_cluster_name
}

data "aws_eks_cluster_auth" "cluster_auth" {
  name = var.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  token                  = data.aws_eks_cluster_auth.cluster_auth.token
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
}
