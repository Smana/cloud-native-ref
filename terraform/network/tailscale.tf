module "tailscale" {
  source = "../modules/tf-module-tailscale"

  region = var.region
  env    = var.env

  name     = var.tailscale.name
  auth_key = var.tailscale.auth_key

  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnets
  advertise_routes = [module.vpc.vpc_cidr_block]

  tags = var.tags

}
