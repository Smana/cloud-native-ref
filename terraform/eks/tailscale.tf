module "tailscale" {
  source = "../modules/tf-module-tailscale"

  name   = "ogenki"
  region = "eu-west-3"
  env    = "dev"

  vpc_id           = module.vpc.vpc_id
  subnet_ids       = module.vpc.private_subnets
  advertise_routes = [module.vpc.vpc_cidr_block]

  auth_key = var.tailscale_authkey
}
