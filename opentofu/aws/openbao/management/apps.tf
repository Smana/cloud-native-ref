# Per-app ownership of the `apps/` mount (ADR-0036).
#
# Everything here is gated on `local.oidc_enabled` for the same reason oidc.tf
# is: without the OIDC mount there is no accessor to alias against, and a
# cluster whose ZITADEL is not bootstrapped yet must still converge.
#
# The alias name is what must appear in the token's `groups` array, exactly.
# That claim only arrives when three things hold -- ZITADEL projectRoleAssertion
# true, the groupsFromRoles Action present, and the OIDC role requesting the
# `groups` scope. A group that appears to grant nothing should be diagnosed
# against those three before anything here is suspected; the third was broken
# until the role gained oidc_scopes, and it surfaced as `claim "email" not found
# in token` rather than as a permission error.

locals {
  # `local.oidc_enabled` is computed from the OIDC secret's PAYLOAD, so OpenTofu
  # marks it sensitive -- and a sensitive value cannot be a for_each argument,
  # because instance keys become part of a resource address and would leak.
  #
  # The keys below come from a plain tfvars list, never from the secret, so it
  # is only the GATE that has to be unwrapped. try() covers the other case:
  # when the secret is absent, oidc_enabled was never sensitive to begin with,
  # and nonsensitive() errors on a value that is not sensitive.
  oidc_on = try(nonsensitive(local.oidc_enabled), local.oidc_enabled)

  # Empty when OIDC is off, so no policy or group is generated at all.
  secret_owning_apps = local.oidc_on == 1 ? var.secret_owning_apps : toset([])
}

resource "vault_policy" "app_prefix" {
  for_each = local.secret_owning_apps

  name = "app-${each.value}"
  policy = templatefile("policies/app-prefix.hcl", {
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
