provider "aws" {
  region = var.region
}

provider "vault" {
  address         = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
  token           = jsondecode(data.aws_secretsmanager_secret_version.openbao_root_token_secret.secret_string)["token"]
  namespace       = "openbao"
  skip_tls_verify = true
}
