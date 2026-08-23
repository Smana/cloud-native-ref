stack {
  name        = "Shared Tailscale"
  description = "Tailnet-wide singletons: ACL, DNS nameservers, DNS search paths. Owned by neither cloud"
  id          = "e2cb2f30-bb0d-4bc3-be3f-21754e53bc30"

  # No `after`. Both network stacks depend on THIS one: a subnet router that
  # registers before autoApprovers exists advertises routes that stay pending
  # manual approval, which presents as a routing failure rather than a policy gap.

  tags = [
    "shared",
    "tailscale",
    "network"
  ]
}
