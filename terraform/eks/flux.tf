resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "github_repository_deploy_key" "this" {
  title      = "Flux"
  repository = var.github_repository
  key        = tls_private_key.flux.public_key_openssh
  read_only  = "false"
}

resource "flux_bootstrap_git" "this" {
  path = "clusters/${var.cluster_name}"

  depends_on = [
    github_repository_deploy_key.this,
    helm_release.cilium
  ]
}

resource "kubernetes_config_map" "flux_clusters_vars" {
  metadata {
    name      = "eks-${var.cluster_name}-vars"
    namespace = "flux-system"
  }

  data = {
    cluster_name      = var.cluster_name
    oidc_provider_arn = module.eks.oidc_provider_arn
    oidc_issuer_url   = module.eks.cluster_oidc_issuer_url
    oidc_issuer_host  = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
    aws_account_id    = data.aws_caller_identity.this.account_id
    region            = var.region
    environment       = var.env
    vpc_id            = module.vpc.vpc_id
  }
  depends_on = [flux_bootstrap_git.this]
}

# Write Github secrets in order to use them as variables with flux's variables substitions
resource "kubernetes_secret" "flux_github_creds" {
  metadata {
    name      = "flux-github-creds"
    namespace = "flux-system"
  }

  data = {
    github_owner      = var.github_owner
    github_token      = var.github_token
    github_repository = var.github_repository
  }
  depends_on = [flux_bootstrap_git.this]
}
