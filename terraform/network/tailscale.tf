module "tailscale_subnet_router" {
  source  = "Smana/tailscale-subnet-router/aws"
  version = "1.0.2"

  region = var.region
  env    = var.env

  name     = var.tailscale.name
  auth_key = var.tailscale.auth_key

  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnets
  advertise_routes = [module.vpc.vpc_cidr_block]

  prometheus_node_exporter_enabled = true
  ssm_enabled                      = true

  tags = var.tags

}
