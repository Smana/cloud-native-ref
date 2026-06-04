locals {
  # Gateway API CRDs installed before Cilium (Cilium's Gateway API support
  # requires these CRDs to exist). Version must match
  # flux/sources/gitrepo-gateway-api.yaml ref.
  gateway_api_crds_urls = [
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_gatewayclasses.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_gateways.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_httproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_referencegrants.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_tcproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_udproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_grpcroutes.yaml"
  ]

  cert_manager_approle = jsondecode(data.aws_secretsmanager_secret_version.cert_manager_approle.secret_string)
  github_app_secret    = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)

  oidc_issuer_url  = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_issuer_host = replace(local.oidc_issuer_url, "https://", "")

  # Karpenter SQS queue name. The terraform-aws-modules karpenter submodule
  # defaults to "Karpenter-<cluster_name>" (coalesce(var.queue_name, ...)) and
  # eks/init does not override queue_name, so this matches the created queue.
  karpenter_queue_name = "Karpenter-${var.cluster_name}"
}
