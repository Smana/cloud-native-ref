terraform {
  required_version = "~> 1.5"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }
}
