# Install Gateway API CRD's. Requirement to be installed before Cilium is running
resource "kubectl_manifest" "gateway_api_crds" {
  count      = length(local.gateway_api_crds_urls)
  yaml_body  = data.http.gateway_api_crds[count.index].body
  depends_on = [module.eks.eks_cluster]
}


# Karpenter manifests
resource "kubectl_manifest" "karpenter" {
  for_each = {
    for file_name in flatten([
      data.kubectl_filename_list.karpenter_default.matches,
      data.kubectl_filename_list.karpenter_io.matches
    ]) : file_name => file_name
  }

  yaml_body = templatefile(
    each.key,
    {
      cluster_name                   = module.eks.cluster_name,
      env                            = var.env,
      karpenter_node_iam_role_name   = module.karpenter.node_iam_role_name
      default_nodepool_cpu_limits    = var.karpenter_limits.default.cpu
      default_nodepool_memory_limits = var.karpenter_limits.default.memory
      io_nodepool_cpu_limits         = var.karpenter_limits.io.cpu
      io_nodepool_memory_limits      = var.karpenter_limits.io.memory
    }
  )

  depends_on = [
    helm_release.karpenter
  ]
}

# Flux manifests
resource "kubectl_manifest" "flux" {
  for_each = { for file_name in data.kubectl_filename_list.flux.matches : file_name => file_name }
  yaml_body = templatefile(each.key,
    {
      flux_operator_version               = var.flux_operator_version
      enable_flux_image_update_automation = var.enable_flux_image_update_automation
      repository_sync_url                 = var.flux_sync_repository_url
      git_ref                             = var.flux_git_ref
      cluster_name                        = var.cluster_name
      oidc_provider_arn                   = module.eks.oidc_provider_arn
      oidc_issuer_url                     = module.eks.cluster_oidc_issuer_url
      oidc_issuer_host                    = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
      aws_account_id                      = data.aws_caller_identity.this.account_id
      region                              = var.region
      environment                         = var.env
      vpc_id                              = data.aws_vpc.selected.id
      vpc_cidr_block                      = data.aws_vpc.selected.cidr_block
    }
  )

  depends_on = [helm_release.flux-operator]
}

resource "kubernetes_secret" "flux_system" {
  metadata {
    name      = "flux-system"
    namespace = "flux-system"
  }

  data = {
    for key, value in jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string) :
    key => value
  }

  depends_on = [helm_release.flux-operator]
}


# Set the GP3 storageclass as default
resource "kubernetes_annotations" "gp2" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = "true"

  metadata {
    name = "gp2"
  }

  annotations = {
    # Modify annotations to remove gp2 as default storage class still retain the class
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [
    helm_release.aws_ebs_csi_driver
  ]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      # Annotation to set gp3 as default storage class
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = true
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    helm_release.aws_ebs_csi_driver
  ]
}
