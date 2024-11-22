resource "vault_auth_backend" "approle" {
  type = "approle"
}

resource "vault_approle_auth_backend_role" "snapshot" {
  backend           = vault_auth_backend.approle.path
  role_name         = "snapshot-agent"
  token_policies    = ["snapshot"]
  token_bound_cidrs = var.allowed_cidr_blocks
}

resource "vault_approle_auth_backend_role" "cert_manager" {
  backend           = vault_auth_backend.approle.path
  role_name         = "cert-manager"
  token_policies    = ["cert-manager"]
  token_bound_cidrs = var.allowed_cidr_blocks
  token_ttl         = 600
  token_max_ttl     = 1200
}
