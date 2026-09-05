provider "aws" {
  region = var.region
}

provider "vault" {
  # local.openbao_address (secrets.tf) rather than a second copy of the same
  # ternary: the snapshot job's VAULT_ADDR and the operator credentials blob are
  # built from that local, and two copies could drift into pointing the provider
  # at one endpoint while its consumers get another.
  address = local.openbao_address
  token   = jsondecode(data.aws_secretsmanager_secret_version.openbao_root_token_secret.secret_string)["token"]

  # This stack imports the pre-signed intermediate issuer and writes every
  # policy on the platform. It used to accept any certificate presented to it.
  # The chain it needs is the one already in Secrets Manager and already read
  # by this stack for pki.tf - the deploy workflow writes it to disk before
  # `tofu init`, because a provider block cannot depend on a resource.
  #
  # ca_cert_file is blanked when verification is off, so an unreadable path
  # cannot fail provider configuration on a bootstrap run.
  ca_cert_file    = var.openbao_skip_tls_verify ? "" : var.openbao_ca_cert_file
  skip_tls_verify = var.openbao_skip_tls_verify
}
