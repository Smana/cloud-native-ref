terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Same floor and constraint as every other GCP stack in this repo, to keep
      # one provider version across network, gke and openbao. See
      # opentofu/gcp/network/versions.tf for why 7.17 is the floor.
      version = "~> 7.17"
    }
  }
}

# No google-beta here. Unlike opentofu/gcp/network, this stack consumes no
# module that declares it -- every resource below (KMS key ring/key, service
# account, IAM bindings) is a stable google_* resource. Do not add google-beta
# by reflex; add it only when a resource actually needs it.
