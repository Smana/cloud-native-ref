# The break-glass login. It stays alongside OIDC on purpose (ADR-0034): ZITADEL's
# own credential lives in platform/zitadel/envvars, so an OIDC-only login would
# have no way back in when ZITADEL is down. It MUST carry secrets-admin, or it
# authenticates and then reads nothing it exists to recover.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"
}

# Lands in state, as the root token already does. The caller publishes it to
# its own cloud's secret store from the `admin_password` output.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "vault_generic_endpoint" "admin_user" {
  path = "auth/${vault_auth_backend.userpass.path}/users/${var.admin_username}"
  # The password is never readable back, so a read would always look like drift.
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.admin.name, vault_policy.pki_admin.name, vault_policy.secrets_admin.name]
    password      = random_password.admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}
