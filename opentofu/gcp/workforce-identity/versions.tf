terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Matches every other GCP stack's floor -- see
      # opentofu/gcp/network/versions.tf -- so one provider version applies
      # across network, gke and this stack.
      version = "~> 7.17"
    }
  }
}
