terraform {
  required_version = "~> 1.5"

  required_providers {
    # The OpenBao API is Vault-compatible, so the vault provider drives it.
    # `~> 5.0` admits both callers: AWS pins ~> 5.0, GCP ~> 5.4.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
