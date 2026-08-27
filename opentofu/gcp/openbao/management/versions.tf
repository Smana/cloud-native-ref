terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.0"
    }
    # The OpenBao API is Vault-compatible, so the vault provider drives it.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.4"
    }
  }
}
