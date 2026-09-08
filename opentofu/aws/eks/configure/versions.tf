terraform {
  required_version = ">= 1.5"

  required_providers {
    # The flux-operator bootstrap guard in main.tf shells out through
    # scripts/helm-release-present.sh to ask whether Flux already owns the
    # release.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
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
