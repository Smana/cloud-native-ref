# Vault administrators
resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("policies/admin.hcl")
}

# Cert manager
resource "vault_policy" "cert_manager" {
  name   = "cert-manager"
  policy = file("policies/cert-manager.hcl")
}

# Creating snapshots
resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = file("policies/snapshot.hcl")
}
