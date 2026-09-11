# Per-app ownership of apps/ (ADR-0036). Gated on OIDC: without the OIDC mount
# there is no accessor to alias against.
locals {
  oidc_enabled = var.oidc_client_id != "" && var.oidc_issuer != "" ? 1 : 0

  # The gate is derived from the caller's OIDC secret payload, so it may arrive
  # marked sensitive -- and a sensitive value cannot be a for_each argument.
  # The keys come from a plain list; only the gate needs unwrapping. try()
  # covers the non-sensitive case, where nonsensitive() would error.
  oidc_on            = try(nonsensitive(local.oidc_enabled), local.oidc_enabled)
  secret_owning_apps = local.oidc_on == 1 ? var.secret_owning_apps : toset([])
}

resource "vault_policy" "app_prefix" {
  for_each = local.secret_owning_apps

  name = "app-${each.value}"
  policy = templatefile("${path.module}/policies/app-prefix.hcl", {
    mount = vault_mount.apps.path
    app   = each.value
  })
}

resource "vault_identity_group" "app" {
  for_each = local.secret_owning_apps

  name     = "openbao-app-${each.value}"
  type     = "external"
  policies = [vault_policy.app_prefix[each.value].name]
}

resource "vault_identity_group_alias" "app" {
  for_each = local.secret_owning_apps

  # Must equal the ZITADEL project role name as it lands in the groups claim.
  name           = "app-${each.value}"
  mount_accessor = vault_jwt_auth_backend.oidc[0].accessor
  canonical_id   = vault_identity_group.app[each.value].id
}
