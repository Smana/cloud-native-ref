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
# module that declares it -- the KMS key ring/key are read via data source
# (see kms.tf), and every resource this stack manages (service account, IAM
# bindings, the instance template, MIG) is a stable google_* resource. Do not
# add google-beta by reflex; add it only when a resource actually needs it.
