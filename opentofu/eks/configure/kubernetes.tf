# Cluster-internal bootstrap resources.
#
# These were moved here from eks/init. They must NOT live in the cluster-creating
# stage: there the kubectl/kubernetes providers would be configured from
# module.eks.* outputs that don't exist until the same apply runs, and
# alekc/kubectl cannot defer provider configuration with unknown values
# (fails with "no configuration has been provided, try setting KUBERNETES_MASTER").
# This is the same reason terraform-aws-modules/eks removed the Kubernetes
# provider from the module in v20. Here the cluster already exists
# (data.aws_eks_cluster.this + exec auth), so the providers configure cleanly.

# Install Gateway API CRDs. Requirement to be installed before Cilium is running.
# `force_conflicts = true` because Flux's `crds-gateway-api` Kustomization
# (kube-system) takes over field-managership after the cluster is up — on
# subsequent re-deploys Tofu would otherwise fail with SSA conflicts on
# .spec.versions and the api-approved annotation. Tofu wins on apply,
# Flux re-claims on its next reconcile (~1 min) — the CRD content is
# identical (same upstream URL) so there's no flap.
resource "kubectl_manifest" "gateway_api_crds" {
  count             = length(local.gateway_api_crds_urls)
  yaml_body         = data.http.gateway_api_crds[count.index].body
  server_side_apply = true
  force_conflicts   = true
  wait              = true
}

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
}

# ConfigMap with cluster variables for Flux substitution
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "eks-${var.cluster_name}-vars"
      namespace = "flux-system"
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
    data = {
      cluster_name           = var.cluster_name
      cluster_endpoint       = replace(data.aws_eks_cluster.this.endpoint, "https://", "")
      cluster_endpoint_full  = data.aws_eks_cluster.this.endpoint
      oidc_provider_arn      = data.aws_iam_openid_connect_provider.this.arn
      oidc_issuer_url        = local.oidc_issuer_url
      oidc_issuer_host       = local.oidc_issuer_host
      aws_account_id         = data.aws_caller_identity.this.account_id
      region                 = var.region
      environment            = var.env
      domain_name            = var.public_domain_name
      private_domain_name    = var.private_domain_name
      public_domain_name     = var.public_domain_name
      vpc_id                 = data.aws_vpc.selected.id
      vpc_cidr_block         = data.aws_vpc.selected.cidr_block
      karpenter_queue_name   = local.karpenter_queue_name
      route53_public_zone_id = data.aws_route53_zone.public.zone_id
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

# Create secrets using kubectl_manifest instead of kubernetes_secret
# to avoid plan-time validation issues with the kubernetes provider
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
}
