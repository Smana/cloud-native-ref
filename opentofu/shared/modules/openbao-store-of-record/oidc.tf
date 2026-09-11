# Human login through ZITADEL, authorised by project roles (ADR-0034). Everything
# is count-gated on the caller supplying a client id and an issuer, so a cluster
# whose ZITADEL is not bootstrapped yet applies cleanly with no OIDC method.
locals {
  # BOTH callbacks are required, and must match the `openbao` entry in
  # scripts/zitadel-oidc-clients.sh. The UI path embeds the mount path twice,
  # which is why `path` below is pinned to "oidc".
  oidc_redirect_uris = [
    "${var.openbao_address}/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
}

resource "vault_jwt_auth_backend" "oidc" {
  count = local.oidc_enabled

  path               = "oidc"
  type               = "oidc"
  description        = "ZITADEL OIDC for human operators (ADR-0034)"
  oidc_discovery_url = var.oidc_issuer
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret

  # A LITERAL, not a reference to the role below: referencing it would order the
  # role before the mount it lives in, and a fresh apply fails with
  # `no handler for route "auth/oidc/role/default"`.
  default_role = "default"

  # checkov:skip=CKV_SECRET_6:False positive on `token_type = "default-service"` -- an OpenBao token-type constant, not a base64 secret.
  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "1h"
    max_lease_ttl      = "8h"
    token_type         = "default-service"
  }
}

resource "vault_jwt_auth_backend_role" "oidc_default" {
  count = local.oidc_enabled

  backend   = vault_jwt_auth_backend.oidc[0].path
  role_name = "default"
  role_type = "oidc"

  allowed_redirect_uris = local.oidc_redirect_uris
  user_claim            = "email"
  # Without these ZITADEL issues a token with neither `email` nor `groups`, and
  # the login dies on `claim "email" not found in token`.
  oidc_scopes     = ["profile", "email", "groups"]
  groups_claim    = "groups"
  bound_audiences = [var.oidc_client_id]

  # Authorisation comes from the external group below, never from the role.
  token_policies = []
  token_ttl      = 3600
  token_max_ttl  = 28800
}

resource "vault_identity_group" "oidc_admin" {
  count = local.oidc_enabled

  name     = "openbao-admin"
  type     = "external"
  policies = [vault_policy.admin.name, vault_policy.pki_admin.name, vault_policy.secrets_admin.name]
}

resource "vault_identity_group_alias" "oidc_admin" {
  count = local.oidc_enabled

  # Must equal the value in the token's `groups` array, exactly.
  name           = var.admin_group_alias
  mount_accessor = vault_jwt_auth_backend.oidc[0].accessor
  canonical_id   = vault_identity_group.oidc_admin[0].id
}
