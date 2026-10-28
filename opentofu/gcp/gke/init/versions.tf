terraform {
  required_version = "~> 1.5"

  required_providers {
    google = {
      source = "hashicorp/google"
      # kubernetes-engine v46 wants `>= 7.39.0, < 9`, so 8.x is inside it. This
      # stack is the one that pins the *major*: every other GCP stack follows.
      version = "~> 8.0"
    }
    google-beta = {
      source = "hashicorp/google-beta"
      # 7.39 added kubelet_config's shutdown grace fields (sandbox.tf), and v46
      # of the module floors the provider there.
      version = "~> 8.0"
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
