resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv-v2"
  description = "Store sensitive data"
}
