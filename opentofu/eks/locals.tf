locals {
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
}
