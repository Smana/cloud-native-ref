resource "tailscale_acl" "this" {
  // Overwrite the existing content of the ACL.
  overwrite_existing_content = lookup(var.tailscale, "overwrite_existing_content", false)

  acl = jsonencode({
    // Define access control lists for users, groups, autogroups, tags,
    // Tailscale IP addresses, and subnet ranges.
    // This is an unrestricted rule made for a test environment, connections are allowed from all sources to any destination
    acls = [
      {
        action = "accept"
        src    = ["*"]
        dst    = ["*:*"]
      }
    ]

    // Define users and devices that can use Tailscale SSH.
    ssh = [
      {
        action = "check"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self"]
        users  = ["autogroup:nonroot"]
      }
    ]

    // Allow the subnet router to advertise the VPC CIDR.
    autoApprovers = {
      routes = {
        # tflint-ignore: terraform_deprecated_interpolation
        "${module.vpc.vpc_cidr_block}" = [var.tailscale.tailnet]
      }
    }

    tagOwners = {
      "tag:ci" = [var.tailscale.tailnet]
    }
  })
}

resource "tailscale_dns_nameservers" "this" {
  nameservers = [
    "1.1.1.1" // Cloudflare
  ]
}

resource "tailscale_dns_split_nameservers" "private" {
  domain = var.private_domain_name

  nameservers = [cidrhost(module.vpc.vpc_cidr_block, 2)]
}

resource "tailscale_dns_split_nameservers" "ec2" {
  domain = "${var.region}.compute.internal"

  nameservers = [cidrhost(module.vpc.vpc_cidr_block, 2)]
}

resource "tailscale_dns_search_paths" "this" {
  search_paths = [
    "${var.region}.compute.internal",
    var.private_domain_name
  ]
}

resource "tailscale_tailnet_key" "this" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
}

module "tailscale_subnet_router" {

  source  = "Smana/tailscale-subnet-router/aws"
  version = "1.2.2"

  region = var.region
  env    = var.env

  name     = var.tailscale.subnet_router_name
  auth_key = tailscale_tailnet_key.this.key

  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnets
  advertise_routes      = [module.vpc.vpc_cidr_block]
  tailscale_version     = lookup(var.tailscale, "tailscale_version", "")
  tailscale_ssh_enabled = true

  prometheus_node_exporter_enabled = lookup(var.tailscale, "prometheus_enabled", false) ? true : false
  ssm_enabled                      = lookup(var.tailscale, "ssm_enabled", false) ? true : false

  tags = merge(var.tags,
    {
      app                           = "tailscale"
      "observability:node-exporter" = lookup(var.tailscale, "prometheus_enabled", "false") ? "true" : "false"
    }
  )

}
