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

    acls = concat(
      [
        { action = "accept", src = ["group:admin"], dst = ["tag:admin:*"] },
        { action = "accept", src = ["autogroup:member"], dst = ["tag:ci:*"] },
        { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:*"] },
      ],
      # One rule per cloud (map key), not per CIDR -- matches the live AWS
      # rendering, which has one "autogroup:member" -> [cidrs...] rule per
      # cloud rather than one rule per CIDR. Map iteration is lexicographic by
      # key, so this reproduces AWS's aws-then-gcp ordering without hardcoding
      # it.
      [for _, cidrs in var.advertised_routes : {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = [for c in cidrs : "${c}:*"]
      }],
      [
        { action = "accept", src = ["autogroup:member"], dst = ["autogroup:member:*"] },
        { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*", "tag:admin:*"] },
        # The operator's egress ProxyGroup pods (tag:k8s) carrying a remote
        # cluster's OpenBao traffic to the other cloud's internal load balancer
        # -- security/base/openbao-endpoint/remote. Port 8200 only, to every
        # advertised CIDR: which cloud is active is a per-cluster variable, and
        # the ACL should not have to know.
        {
          action = "accept"
          src    = ["tag:k8s"]
          dst    = [for c in flatten(values(var.advertised_routes)) : "${c}:8200"]
        },
      ]
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
