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
