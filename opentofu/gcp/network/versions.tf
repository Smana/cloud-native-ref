terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 7.17 is the floor terraform-google-modules/kubernetes-engine v44 sets.
      # Pinning the same constraint in every GCP stack keeps one provider version
      # across network and gke. Both CFT modules cap at < 8.
      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.17"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
    # Only for the inbound-DNS allocation wait in tailscale.tf. Same provider
    # the AWS llm-platform stack uses for EFS mount-target propagation.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
