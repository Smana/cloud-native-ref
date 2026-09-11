# Offline: mocked providers, so no OpenBao is needed. `command = apply` because
# the break-glass user's data_json embeds the generated password, which is only
# known after an apply -- and under mock providers an apply calls nothing real.
mock_provider "vault" {}
mock_provider "random" {}

variables {
  pki_mount_path  = "pki_private_issuer"
  openbao_address = "https://bao.priv.gcp.ogenki.io:8200"
}

run "mounts_policies_and_break_glass_without_oidc" {
  command = apply

  assert {
    condition     = vault_mount.platform.path == "platform" && vault_mount.apps.path == "apps"
    error_message = "the two Stage 2 mounts must be platform/ and apps/"
  }
  assert {
    condition     = vault_mount.platform.type == "kv-v2" && vault_mount.apps.type == "kv-v2"
    error_message = "both mounts must be kv-v2: the ClusterSecretStores read with version v2"
  }
  assert {
    condition     = vault_policy.external_secrets.name == "external-secrets"
    error_message = "the JWT roles reference this policy BY NAME: it must be external-secrets"
  }
  assert {
    condition     = length(vault_jwt_auth_backend.oidc) == 0 && length(vault_identity_group.oidc_admin) == 0
    error_message = "OIDC must stay off without a client id and an issuer"
  }
  assert {
    condition     = length(vault_policy.app_prefix) == 0
    error_message = "per-app personas alias the OIDC mount, so they must not exist without it"
  }
  assert {
    condition     = contains(jsondecode(vault_generic_endpoint.admin_user.data_json).policies, "secrets-admin")
    error_message = "the break-glass login must carry secrets-admin, or it cannot read what it exists to recover"
  }
}

run "oidc_group_and_personas_when_configured" {
  command = apply

  variables {
    oidc_client_id     = "fixture-client"
    oidc_client_secret = "fixture-value" # pragma: allowlist secret
    oidc_issuer        = "https://auth.gcp.cloud.ogenki.io"
    secret_owning_apps = ["app-wizard", "image-gallery"]
  }

  assert {
    condition     = length(vault_jwt_auth_backend.oidc) == 1 && vault_jwt_auth_backend.oidc[0].path == "oidc"
    error_message = "the OIDC mount must exist, at the pinned path oidc/"
  }
  assert {
    condition     = vault_identity_group_alias.oidc_admin[0].name == "platform"
    error_message = "the openbao-admin group must alias the matrix's platform team"
  }
  assert {
    condition     = contains(vault_identity_group.oidc_admin[0].policies, "secrets-admin")
    error_message = "openbao-admin must carry secrets-admin"
  }
  assert {
    condition     = length(vault_policy.app_prefix) == 2
    error_message = "one policy per secret-owning app"
  }
  assert {
    condition     = contains(vault_jwt_auth_backend_role.oidc_default[0].oidc_scopes, "groups") && contains(vault_jwt_auth_backend_role.oidc_default[0].oidc_scopes, "email")
    error_message = "the default role must request groups and email, or the login dies on `claim \"email\" not found in token`"
  }
  assert {
    condition     = contains(vault_jwt_auth_backend_role.oidc_default[0].allowed_redirect_uris, "https://bao.priv.gcp.ogenki.io:8200/ui/vault/auth/oidc/oidc/callback")
    error_message = "the UI callback must match what scripts/zitadel-oidc-clients.sh registers"
  }
}
