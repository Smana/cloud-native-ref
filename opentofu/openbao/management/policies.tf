# Namespace attribute discipline: always address a namespace by `path_fq`.
# `vault_namespace.admin.namespace` is the *parent* of the `admin` namespace —
# an empty string, i.e. root — so reading it here silently wrote these policies
# to the root namespace, while the AppRole roles that reference them by name
# live in `admin` (auth.tf). Policy names resolve within the token's own
# namespace, so `snapshot-agent` was bound to a policy that did not exist there
# and its tokens carried no capabilities at all. `path` and `path_fq` happen to
# agree for a single-level namespace, which is what let this hide.

# Vault administrators
resource "vault_policy" "admin" {
  namespace = vault_namespace.admin.path_fq
  name      = "admin"
  policy    = file("policies/admin.hcl")
}

# Creating snapshots
resource "vault_policy" "snapshot" {
  namespace = vault_namespace.admin.path_fq
  name      = "snapshot"
  policy    = file("policies/snapshot.hcl")
}

# Cert manager
resource "vault_policy" "cert_manager" {
  namespace = vault_namespace.pki.path_fq
  name      = "cert-manager"
  policy    = file("policies/cert-manager.hcl")
}
