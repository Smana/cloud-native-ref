locals {
  # Gateway API CRDs installed before Cilium (Cilium's Gateway API support
  # requires these CRDs to exist). Version must match
  # flux/sources/gitrepo-gateway-api.yaml ref.
  #
  # THIS LIST IS LOAD-BEARING AND MUST COVER EVERYTHING CILIUM LOOKS FOR.
  # The cilium-operator probes for the Gateway API CRDs exactly once, at startup.
  # If any are missing it logs "Required GatewayAPI resources are not found",
  # disables its Gateway API controller and NEVER RETRIES — every GatewayClass
  # then sits at Accepted=Unknown "Waiting for controller", every Gateway stays
  # unprogrammed, and HTTPRoutes get no status at all. Nothing crashes and
  # nothing alerts.
  #
  # Flux applies the whole ./config/crd/experimental directory
  # (crds/base/kustomization-gateway-api.yaml), but that runs well after
  # eks/configure installs Cilium, so anything only Flux applies loses the race.
  # That is exactly how backendtlspolicies was missed: Cilium 1.20 requires it,
  # this list did not have it, and the operator gave up two seconds before Flux
  # created it.
  #
  # Append new entries — the `count` index of the existing ones must not shift,
  # or tofu destroys and recreates live CRDs, taking every Gateway and HTTPRoute
  # with them. Recovery if it happens again: restart the operator, which reruns
  # the probe (`kubectl rollout restart -n kube-system deployment/cilium-operator`).
  gateway_api_crds_urls = [
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_gatewayclasses.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_gateways.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_httproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_referencegrants.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_tcproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_udproutes.yaml",
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_grpcroutes.yaml",
    # Required by Cilium >= 1.20. Its absence is what broke Gateway API on the
    # 2026-08-19 rebuild.
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_backendtlspolicies.yaml",
    # Not required, but detected only at operator startup: "The ListenerSet CRD
    # must be installed before the Cilium operator starts to ensure detection.
    # If the CRD is added to an existing installation, the Cilium operator must
    # be restarted" — docs.cilium.io/en/stable/network/servicemesh/gateway-api/listenerset
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${var.gateway_api_version}/config/crd/experimental/gateway.networking.k8s.io_listenersets.yaml"
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
