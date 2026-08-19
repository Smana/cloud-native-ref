# Snapshot agent — deliberately in the ROOT namespace.
#
# `sys/storage/raft/*` is a restricted endpoint: "Clients must call the API path
# from the root namespace." Raft is a property of the cluster, not of a
# namespace, so there is no per-namespace version of it. This auth backend, its
# role and vault_policy.snapshot previously all sat in `admin`, which meant the
# snapshot agent's token could never reach the endpoint at all — the path
# resolves to 404 "unsupported path" outside root, whatever the policy says.
#
# No `namespace` argument: that is how the provider addresses the root namespace.
resource "vault_auth_backend" "approle_snapshot" {
  type = "approle"
  path = "approle"
}

resource "vault_approle_auth_backend_role" "snapshot" {
  backend           = vault_auth_backend.approle_snapshot.path
  role_name         = "snapshot-agent"
  token_policies    = ["snapshot"]
  token_bound_cidrs = var.allowed_cidr_blocks
}


resource "vault_auth_backend" "approle_pki" {
  namespace = vault_namespace.pki.path_fq
  type      = "approle"
}

resource "vault_approle_auth_backend_role" "cert_manager" {
  namespace         = vault_namespace.pki.path_fq
  backend           = vault_auth_backend.approle_pki.path
  role_name         = "cert-manager"
  token_policies    = ["cert-manager"]
  token_bound_cidrs = var.allowed_cidr_blocks
  token_ttl         = 600
  token_max_ttl     = 1200
}

# Human operator logins
# ---------------------
# CLAUDE.md has always documented `bao auth -method=userpass username=admin`,
# but the backend and the user were created by hand - the same drift problem the
# snapshot AppRole had, on the credential with the widest reach.
#
# There are two of them because policies bind only within their own namespace:
# `admin` for the general admin policy, `admin/pki` for pki-admin. A single
# login covering both would depend on cross-namespace policy resolution, which
# is not something to rely on for an access-control boundary without testing it.
#
# Deliberately not token_bound_cidrs, unlike the machine roles above: the only
# route to this API is the internal NLB, so the network is already constrained,
# and a CIDR bind on the break-glass credential buys nothing against the risk of
# locking yourself out of your own secrets store.

resource "vault_auth_backend" "userpass_admin" {
  namespace = vault_namespace.admin.path_fq
  type      = "userpass"
  path      = "userpass"
}

resource "vault_generic_endpoint" "admin_user" {
  namespace = vault_namespace.admin.path_fq
  path      = "auth/${vault_auth_backend.userpass_admin.path}/users/${var.admin_username}"
  # The password is never readable back from OpenBao, so a read would always
  # look like drift.
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.admin.name]
    password      = random_password.admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}

resource "vault_auth_backend" "userpass_pki" {
  namespace = vault_namespace.pki.path_fq
  type      = "userpass"
  path      = "userpass"
}

resource "vault_generic_endpoint" "pki_admin_user" {
  namespace            = vault_namespace.pki.path_fq
  path                 = "auth/${vault_auth_backend.userpass_pki.path}/users/${var.admin_username}"
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.pki_admin.name]
    password      = random_password.pki_admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}
