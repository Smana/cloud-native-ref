# Platform auth, root namespace
# -----------------------------
# One AppRole backend hosts both machine roles. They used to sit in separate
# backends in separate namespaces (`admin` and `admin/pki`), which bought
# nothing: the roles are already independent units of authorisation, and the
# namespace split actively broke the snapshot agent, since `sys/storage/raft/*`
# is callable only from root.
#
# Resources here take no `namespace` argument — that is how the provider
# addresses the root namespace.

resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

# Raft snapshots. `sys/storage/raft/*` is a restricted endpoint: "Clients must
# call the API path from the root namespace." Raft is a property of the cluster,
# so there is no per-namespace version of it, and a token from any child
# namespace gets 404 "unsupported path" no matter what its policy grants.
resource "vault_approle_auth_backend_role" "snapshot" {
  backend           = vault_auth_backend.approle.path
  role_name         = "snapshot-agent"
  token_policies    = [vault_policy.snapshot.name]
  token_bound_cidrs = var.allowed_cidr_blocks
}

# cert-manager. The ClusterIssuer authenticates here and issues from
# pki_private_issuer; both are now in root, so the issuer manifest no longer
# needs a `namespace` field.
resource "vault_approle_auth_backend_role" "cert_manager" {
  backend           = vault_auth_backend.approle.path
  role_name         = "cert-manager"
  token_policies    = [vault_policy.cert_manager.name]
  token_bound_cidrs = var.allowed_cidr_blocks
  token_ttl         = 600
  token_max_ttl     = 1200
}

# Human operator login
# --------------------
# CLAUDE.md has always documented `bao auth -method=userpass username=admin`,
# but the backend and the user were created by hand — the same drift problem the
# snapshot AppRole had, on the credential with the widest reach.
#
# One login now, carrying both platform policies. The earlier layout forced one
# login per namespace, because a policy binds only within the namespace it is
# created in; collapsing the platform into root removes that.
#
# Deliberately no token_bound_cidrs, unlike the machine roles above: the only
# route to this API is the internal NLB, so the network is already constrained,
# and a CIDR bind on the break-glass credential buys nothing against the risk of
# locking yourself out of your own secrets store.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"
}

resource "vault_generic_endpoint" "admin_user" {
  path = "auth/${vault_auth_backend.userpass.path}/users/${var.admin_username}"
  # The password is never readable back from OpenBao, so a read would always
  # look like drift.
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.admin.name, vault_policy.pki_admin.name]
    password      = random_password.admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}

# Tenant auth: app namespace
# --------------------------
# The `app` namespace held a kv-v2 mount with no auth method, no policy and no
# role, so nothing but a root token could read it. This makes it reachable and
# gives the tenancy model one worked example.
#
# No secret_id is generated here on purpose: there is no consumer yet, and an
# unused live credential is worse than none. Mint one with
# `bao write -f -namespace=app auth/approle/role/app/secret-id` when something
# needs it.
resource "vault_auth_backend" "approle_app" {
  namespace = vault_namespace.app.path_fq
  type      = "approle"
  path      = "approle"
}

resource "vault_approle_auth_backend_role" "app" {
  namespace         = vault_namespace.app.path_fq
  backend           = vault_auth_backend.approle_app.path
  role_name         = "app"
  token_policies    = [vault_policy.app.name]
  token_bound_cidrs = var.allowed_cidr_blocks
  token_ttl         = 1800
  token_max_ttl     = 3600
}
