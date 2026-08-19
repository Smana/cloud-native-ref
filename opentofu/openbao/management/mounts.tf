resource "vault_mount" "app_secret" {
  namespace   = vault_namespace.app.path_fq
  path        = "secret"
  type        = "kv-v2"
  description = "Store sensitive data"
}
