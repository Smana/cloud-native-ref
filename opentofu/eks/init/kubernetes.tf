# Install Gateway API CRD's. Requirement to be installed before Cilium is running
resource "kubectl_manifest" "gateway_api_crds" {
  count             = length(local.gateway_api_crds_urls)
  yaml_body         = data.http.gateway_api_crds[count.index].body
  server_side_apply = true
  wait              = true
  depends_on        = [module.eks.cluster_name]
}

# Cilium CNI ConfigMap is created in Stage 2 (opentofu/eks/configure/)
# Cilium and Flux are deployed via Stage 2
# See: cd opentofu/eks/configure && terramate script run deploy

# Create flux-system namespace first (required for secrets and ConfigMap)
resource "kubectl_manifest" "flux_system_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "flux-system"
    }
  })
  server_side_apply = true
  depends_on        = [module.eks]
}

# ConfigMap with cluster variables for Flux substitution
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "eks-${var.name}-vars"
      namespace = "flux-system"
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
    data = {
      cluster_name           = var.name
      cluster_endpoint       = replace(module.eks.cluster_endpoint, "https://", "")
      cluster_endpoint_full  = module.eks.cluster_endpoint
      oidc_provider_arn      = module.eks.oidc_provider_arn
      oidc_issuer_url        = module.eks.cluster_oidc_issuer_url
      oidc_issuer_host       = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
      aws_account_id         = data.aws_caller_identity.this.account_id
      region                 = var.region
      environment            = var.env
      domain_name            = var.domain_name
      vpc_id                 = data.aws_vpc.selected.id
      vpc_cidr_block         = data.aws_vpc.selected.cidr_block
      karpenter_queue_name   = module.karpenter.queue_name
      route53_public_zone_id = data.aws_route53_zone.public.zone_id
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

# Create secrets using kubectl_manifest instead of kubernetes_secret
# to avoid plan-time validation issues with the kubernetes provider
locals {
  cert_manager_approle = jsondecode(data.aws_secretsmanager_secret_version.cert_manager_approle.secret_string)
  github_app_secret    = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)
}

resource "kubectl_manifest" "flux_cert_manager_approle" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "cert-manager-openbao-approle"
      namespace = "flux-system"
    }
    type = "Opaque"
    data = {
      cert_manager_approle_id     = base64encode(local.cert_manager_approle.cert_manager_approle_id)
      cert_manager_approle_secret = base64encode(local.cert_manager_approle.cert_manager_approle_secret)
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

resource "kubectl_manifest" "flux_system_secret" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "flux-system"
      namespace = "flux-system"
    }
    type = "Opaque"
    data = {
      for key, value in local.github_app_secret :
      key => base64encode(value)
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

# gp3 StorageClass (default) - EBS CSI Driver is deployed as EKS managed add-on
resource "kubectl_manifest" "gp3_storageclass" {
  yaml_body         = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp3
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: ebs.csi.aws.com
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      encrypted: "true"
      fsType: ext4
      type: gp3
  YAML
  server_side_apply = true

  depends_on = [module.eks]
}

# Remove gp2 as default StorageClass
resource "kubectl_manifest" "gp2_not_default" {
  yaml_body         = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp2
      annotations:
        storageclass.kubernetes.io/is-default-class: "false"
    provisioner: kubernetes.io/aws-ebs
    parameters:
      type: gp2
      fsType: ext4
    volumeBindingMode: WaitForFirstConsumer
  YAML
  server_side_apply = true

  depends_on = [module.eks]
}
