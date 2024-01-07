provider "vault" {
  address = var.vault_domain_name == "" ? format("https://vault.%s:8200", var.domain_name) : var.vault_domain_name
}
