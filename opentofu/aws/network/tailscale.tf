# Tailnet-wide singletons are NOT declared here. They live in
# opentofu/shared/tailscale, which is their single owner.
#
# tailscale_acl, tailscale_dns_nameservers and tailscale_dns_search_paths are
# TAILNET-scoped, not VPC-scoped: one object per tailnet, shared by every cloud.
# Declaring them here as well as in the shared stack meant two authoritative
# owners in two states with no common lock, so the last apply won. They had
# already diverged -- this file rendered 2 search paths while the shared stack
# renders 3, so an apply here would silently delete priv.gcp.ogenki.io from the
# tailnet and break GCP private DNS for every device on it.
#
# What REMAINS below is correctly per-cloud: split-DNS maps a domain to a
# resolver address, and that address exists only inside this VPC. Same for the
# subnet router's own auth key.

resource "tailscale_dns_split_nameservers" "private" {
  domain = var.private_domain_name

  nameservers = [cidrhost(module.vpc.vpc_cidr_block, 2)]
}

resource "tailscale_dns_split_nameservers" "ec2" {
  domain = "${var.region}.compute.internal"

  nameservers = [cidrhost(module.vpc.vpc_cidr_block, 2)]
}

resource "tailscale_tailnet_key" "this" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
}

module "tailscale_subnet_router" {

  source  = "Smana/tailscale-subnet-router/aws"
  version = "1.3.0"

  region = var.region
  env    = var.env

  name     = var.tailscale_config.subnet_router_name
  auth_key = tailscale_tailnet_key.this.key

  # t3.micro, not the module default t3a.micro: AMD pools are the thinnest in
  # eu-west-3 and 3a ran out (InsufficientInstanceCapacity on deploy). Intel t3
  # is the same amd64 arch, so it needs no AMI or user-data change. Not t4g:
  # Graviton is arm64, which needs an arm64 ami_filter AND breaks the module's
  # node_exporter install (hardcoded linux-amd64 tarball, and we run with
  # prometheus_enabled = true).
  instance_type = lookup(var.tailscale_config, "instance_type", "t3.micro")

  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnets
  advertise_routes      = [module.vpc.vpc_cidr_block]
  tailscale_version     = lookup(var.tailscale_config, "tailscale_version", "")
  tailscale_ssh_enabled = true

  prometheus_node_exporter_enabled = lookup(var.tailscale_config, "prometheus_enabled", false) ? true : false
  ssm_enabled                      = lookup(var.tailscale_config, "ssm_enabled", false) ? true : false

  tags = merge(var.tags,
    {
      app                           = "tailscale"
      "observability:node-exporter" = var.tailscale_config.prometheus_enabled ? "true" : "false"
    }
  )

}
