# Per-app ownership of apps/ (ADR-0036). Gated on OIDC: without the OIDC mount
# there is no accessor to alias against.
locals {
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
