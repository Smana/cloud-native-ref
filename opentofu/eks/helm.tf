resource "helm_release" "cilium" {
  name            = "cilium"
  atomic          = true
  force_update    = true
  cleanup_on_fail = false
  replace         = true
  timeout         = 800 # Should wait for nodes to be ready
  repository      = "https://helm.cilium.io"
  chart           = "cilium"
  version         = var.cilium_version
  namespace       = "kube-system"

  set {
    name  = "cluster.name"
    value = var.cluster_name
  }

  values = [
    templatefile("${path.module}/helm_values/cilium.yaml",
      {
        cluster_endpoint = replace(module.eks.cluster_endpoint, "https://", "")
      }
    )
  ]

  depends_on = [
    kubectl_manifest.gateway_api_crds,
  ]
}

resource "helm_release" "aws_ebs_csi_driver" {
  name            = "aws-ebs-csi-driver"
  atomic          = true
  force_update    = true
  cleanup_on_fail = false
  replace         = true
  timeout         = 180
  repository      = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
  chart           = "aws-ebs-csi-driver"
  version         = var.ebs_csi_driver_chart_version
  namespace       = "kube-system"

  set {
    name  = "controller.k8sTagClusterId"
    value = var.cluster_name
  }
  set {
    name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_ebs_csi_driver.iam_role_arn
  }

  values = [
    file("${path.module}/helm_values/aws-ebs-csi-driver.yaml")
  ]

  depends_on = [helm_release.cilium]
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  values = [
    templatefile(
      "${path.module}/helm_values/karpenter.yaml",
      {
        cluster_name     = module.eks.cluster_name,
        cluster_endpoint = module.eks.cluster_endpoint,
        queue_name       = module.karpenter.queue_name
    })
  ]

  depends_on = [helm_release.cilium]
}

resource "helm_release" "flux-operator" {
  name             = "flux-operator"
  namespace        = "flux-system"
  atomic           = true
  force_update     = true
  cleanup_on_fail  = false
  replace          = true
  timeout          = 180
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.flux_operator_version
  create_namespace = true

  depends_on = [helm_release.cilium]
}
