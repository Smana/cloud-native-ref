provider "aws" {
  region = var.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

provider "helm" {
  kubernetes = {
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
