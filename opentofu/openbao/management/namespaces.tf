resource "vault_namespace" "admin" {
  path = "admin"
}

resource "vault_namespace" "app" {
  path = "app"
}

resource "vault_namespace" "pki" {
  namespace = vault_namespace.admin.path
  path      = "pki"
}
