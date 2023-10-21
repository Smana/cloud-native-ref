resource "helm_release" "cilium" {
  name            = "cilium"
  atomic          = true
  force_update    = true
  cleanup_on_fail = false
  replace         = true
  timeout         = 180
  repository      = "https://helm.cilium.io"
  chart           = "cilium"
  version         = var.cilium_version
  namespace       = "kube-system"

  set {
    name  = "cluster.name"
    value = var.cluster_name
  }

  values = [
    file("${path.module}/helm_values/cilium.yaml")
  ]

  depends_on = [
    kubectl_manifest.gateway_api_crds,
    kubernetes_job.delete_aws_cni_ds
  ]
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "v0.31.1"

  values = [
    templatefile(
      "${path.module}/helm_values/karpenter.yaml",
      {
        cluster_name          = module.eks.cluster_name,
        cluster_endpoint      = module.eks.cluster_endpoint,
        irsa_arn              = module.karpenter.irsa_arn
        instance_profile_name = module.karpenter.instance_profile_name
        queue_name            = module.karpenter.queue_name
    })
  ]

  depends_on = [helm_release.cilium]
}
