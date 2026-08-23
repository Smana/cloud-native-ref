stack {
  name        = "Network"
  description = "Tailscale VPN,VPC, subnets, etc."
  id          = "3564c93f-543f-47c9-9a84-a1d4b5ed7461"

  # shared/tailscale owns the tailnet-wide singletons (ACL, DNS nameservers,
  # search paths) and the autoApprovers this stack's subnet router relies on.
  # Ordering was documented in shared/tailscale/stack.tm.hcl but never enforced.
  after = [
    "/opentofu/shared/tailscale"
  ]

  tags = [
    "aws",
    "network",
    "infrastructure"
  ]
}
