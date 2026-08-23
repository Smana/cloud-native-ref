# The three tailnet-wide singletons.
#
# These live here, and nowhere else, because there is exactly ONE of each per
# tailnet. When they lived in the AWS network stack, the GCP subnet router's
# routes had to be authorised from AWS -- and a second tailscale_acl in the GCP
# stack would have made each apply silently overwrite the other's, last apply
# winning, with no error.
resource "tailscale_acl" "this" {
  overwrite_existing_content = true

  acl = jsonencode({
    groups = {
      "group:admin" = var.admin_users
    }

    acls = concat([
      { action = "accept", src = ["group:admin"], dst = ["tag:admin:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["tag:ci:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:member:*"] },
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*", "tag:admin:*"] },
      ],
      # One rule per cloud, generated from the same map that drives
      # autoApprovers below, so a route can never be auto-approved yet
      # unreachable -- the failure mode that looks like a routing bug.
      [for cidr in flatten(values(var.advertised_routes)) : {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["${cidr}:*"]
      }]
    )

    ssh = [
      {
        action = "check"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self"]
        users  = ["autogroup:nonroot"]
      }
    ]

    autoApprovers = {
      routes = { for cidr in flatten(values(var.advertised_routes)) : cidr => [var.tailnet] }
    }

    tagOwners = {
      "tag:ci"           = [var.tailnet]
      "tag:k8s"          = ["tag:k8s-operator"]
      "tag:k8s-operator" = [var.tailnet]
      "tag:admin"        = ["tag:k8s-operator"]
    }
  })
}

resource "tailscale_dns_nameservers" "this" {
  nameservers = [
    "1.1.1.1" # Cloudflare
  ]
}

# A LIST, and tailnet-wide. Before this stack existed it held only the AWS
# entries, so GCP private names would not have resolved from a tailnet device
# even with the GCP router up and its routes approved.
resource "tailscale_dns_search_paths" "this" {
  search_paths = var.search_domains
}
