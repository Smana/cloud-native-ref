module "gateway_api_crds" {
  source = "../../../shared/modules/gateway-api-crds"

  gateway_api_version = var.gateway_api_version
}
