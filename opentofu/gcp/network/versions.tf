terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # Pinning the same constraint in every GCP stack keeps one provider version
      # across network, gke and openbao. Both CFT modules accept 8.x: the VPC
      # module wants `>= 4.64, < 9`, kubernetes-engine v46 `>= 7.39.0, < 9`. The
      # old `~> 7.17` was the ceiling these stacks were left at, not a floor.
      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.0"
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
