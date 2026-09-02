provider "aws" {
  region = var.region
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 15
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
  load_config_file = false
}

# OpenBao, for the JWT auth mount this cluster authenticates through
# (openbao.tf). Configured like the management stack: the lineage root token
# from Secrets Manager, and the CA chain the deploy workflow writes to .tls/
# before `tofu init` -- a provider block cannot depend on a resource.
provider "vault" {
  address      = "https://bao.${var.private_domain_name}:8200"
  token        = jsondecode(data.aws_secretsmanager_secret_version.openbao_root_token.secret_string)["token"]
  ca_cert_file = var.openbao_ca_cert_file
}
