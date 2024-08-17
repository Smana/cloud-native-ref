resource "flux_bootstrap_git" "this" {
  path               = "clusters/${var.cluster_name}"
  embedded_manifests = true

  depends_on = [
    helm_release.cilium
  ]
}

# Write a ConfigMap for use with Flux's variable substitutions
# Creating it before Flux bootstrap in order to speed up the first reconciliation
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  # Ignore changes to labels to avoid because they are modified by Flux bootstrap.
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
    ]
  }

  depends_on = [module.eks]
}

resource "kubernetes_config_map" "flux_clusters_vars" {
  metadata {
    name      = "eks-${var.cluster_name}-vars"
    namespace = "flux-system"
  }

  data = {
    cluster_name       = var.cluster_name
    oidc_provider_arn  = module.eks.oidc_provider_arn
    oidc_issuer_url    = module.eks.cluster_oidc_issuer_url
    oidc_issuer_host   = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
    aws_account_id     = data.aws_caller_identity.this.account_id
    region             = var.region
    environment        = var.env
    vpc_id             = data.aws_vpc.selected.id
    vpc_cidr_block     = data.aws_vpc.selected.cidr_block
    private_subnet_ids = jsonencode(data.aws_subnets.private.ids)
  }
  depends_on = [kubernetes_namespace.flux_system]
}
