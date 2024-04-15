provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "flux" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    token                  = data.aws_eks_cluster_auth.cluster_auth.token
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  }
  git = {
    url    = "ssh://git@github.com/${var.github_owner}/${var.github_repository}.git"
    branch = var.github_branch
    ssh = {
      username    = "git"
      private_key = tls_private_key.flux.private_key_pem
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster_auth.token
  }
}

provider "kubectl" {
  apply_retry_count      = 15
  host                   = module.eks.cluster_endpoint
  token                  = data.aws_eks_cluster_auth.cluster_auth.token
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
}


provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.cluster_auth.token
}


provider "github" {
  owner = var.github_owner
  token = jsondecode(data.aws_secretsmanager_secret_version.github_token.secret_string)["github-token"]
}
