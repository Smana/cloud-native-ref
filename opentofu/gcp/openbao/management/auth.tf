# One AppRole backend hosting one role. The AWS stack hosts two (snapshot and
# cert-manager); the snapshot role has no GCP consumer because nothing backs up
# this PKI yet -- recorded as a risk in the design rather than solved here.
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

resource "vault_approle_auth_backend_role" "cert_manager" {
  backend        = vault_auth_backend.approle.path
  role_name      = "cert-manager"
  token_policies = [vault_policy.cert_manager.name]

  # Short-lived tokens. cert-manager re-authenticates per issuance, so a long
  # TTL buys nothing and widens the window on a leaked token.
  token_ttl     = 600
  token_max_ttl = 1200

  # NOTE: no token_bound_cidrs, unlike AWS.
  #
  # The AWS role binds to the VPC CIDR. Here the caller is a pod behind Cilium's
  # masquerading, reaching OpenBao over the tailnet -- the source address it
  # presents is not something this stack can predict from the network stack's
  # outputs, and a wrong CIDR fails closed at issuance time with an error that
  # points at the AppRole rather than the network. Left off deliberately;
  # revisit once the GKE egress path to the tailnet is pinned down.
}
