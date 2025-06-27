# Vault administrators
resource "vault_policy" "admin" {
  namespace = vault_namespace.admin.namespace
  name      = "admin"
  policy    = file("policies/admin.hcl")
}

# Creating snapshots
resource "vault_policy" "snapshot" {
  namespace = vault_namespace.admin.namespace
  name      = "snapshot"
  policy    = file("policies/snapshot.hcl")
}

# Cert manager
resource "vault_policy" "cert_manager" {
  namespace = vault_namespace.pki.path_fq
  name      = "cert-manager"
  policy    = file("policies/cert-manager.hcl")
}
