provider "vault" {
  address = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
}
