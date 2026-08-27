terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 7.17 is the floor terraform-google-modules/kubernetes-engine v44 sets.
      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.17"
    }
  }
}

# No kubectl/kubernetes/helm provider here on purpose, mirroring
# opentofu/aws/eks/init/providers.tf: this stage only creates the cluster. A provider
# configured from module.gke.* outputs would depend on resources created in this
# same apply, which alekc/kubectl cannot defer -- it fails with "no configuration
# has been provided" on a fresh apply. Every cluster-internal resource, the
# Gateway API CRDs included, lives in gke/configure, which runs against an
# already-created cluster.
