resource "tailscale_acl" "this" {
  // Overwrite the existing content of the ACL.
  overwrite_existing_content = lookup(var.tailscale_config, "overwrite_existing_content", false)

  acl = jsonencode({
    // Define groups for access control
    groups = {
      "group:admin" = ["smainklh@gmail.com"]
    }

    // Define access control lists for users, groups, autogroups, tags,
    // Tailscale IP addresses, and subnet ranges.
    // Note: Only explicitly allowed connections are permitted (default deny)
    acls = [
      // Restrict admin-tagged services (like Hubble) to admin group only
      {
        action = "accept"
        src    = ["group:admin"]
        dst    = ["tag:admin:*"]
      },
      // Allow all members to access CI tagged devices
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["tag:ci:*"]
      },
      // Allow all members to access k8s general services
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["tag:k8s:*"]
      },
      // Allow all members to access VPC resources through subnet router
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["10.0.0.0/16:*"]
      },
      // Allow all members to access other member devices
      {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["autogroup:member:*"]
      },
      // Allow k8s operator to manage its resources
      {
        action = "accept"
        src    = ["tag:k8s-operator"]
        dst    = ["tag:k8s:*", "tag:admin:*"]
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
        "${module.vpc.vpc_cidr_block}" = [var.tailscale_config.tailnet]
      }
    }

    tagOwners = {
      "tag:ci"           = [var.tailscale_config.tailnet]
      "tag:k8s"          = ["tag:k8s-operator"]
      "tag:k8s-operator" = [var.tailscale_config.tailnet]
      "tag:admin"        = ["tag:k8s-operator"]
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
  version = "1.2.3"

  region = var.region
  env    = var.env

  name     = var.tailscale_config.subnet_router_name
  auth_key = tailscale_tailnet_key.this.key

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
