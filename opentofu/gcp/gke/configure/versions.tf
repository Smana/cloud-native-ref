terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.17"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # gavinbunney, matching opentofu/aws/eks/configure — one kubectl provider across
    # both clouds so behaviour differences are not mistaken for cloud differences.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
  }
}
