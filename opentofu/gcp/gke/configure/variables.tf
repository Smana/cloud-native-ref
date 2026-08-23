variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "env" {
  description = "Environment. Substituted into shared manifests as `environment` via the Flux postBuild ConfigMap"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west4"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gcp-mycluster-0"
}

variable "cilium_version" {
  description = "Cilium chart version. SHARED with AWS via opentofu/config.tm.hcl so both clouds upgrade together"
  type        = string
  # Default mirrors `cilium_version` in opentofu/config.tm.hcl. The Terramate
  # scripts pass -var=cilium_version=... at run time, so this is only consulted
  # when running tofu directly in this directory. Same pattern, and same reason,
  # as opentofu/aws/eks/configure/variables.tf.
  default = "1.20.0"
}

variable "flux_operator_version" {
  description = "Flux Operator chart version. Shared with AWS"
  type        = string
  default     = "0.55.0"
}

variable "flux_instance_version" {
  description = "Flux Instance chart version. Shared with AWS"
  type        = string
  default     = "0.55.0"
}

variable "flux_sync_url" {
  description = "Git repository Flux syncs from"
  type        = string
  default     = "https://github.com/Smana/cloud-native-ref.git"
}

variable "flux_git_ref" {
  description = "Git ref Flux tracks. Override with TF_VAR_flux_git_ref=refs/heads/<branch> to deploy a feature branch"
  type        = string
  default     = "refs/heads/main"
}

variable "flux_github_app_secret_name" {
  description = "GCP Secret Manager secret holding Flux's GitHub App credentials. Deliberately NOT AWS Secrets Manager: reading it from AWS would put a hard AWS dependency in the GCP bootstrap"
  type        = string
  default     = "flux-github-app"
}

variable "gateway_api_version" {
  description = "Gateway API release applied before Cilium. MUST equal flux/sources/gitrepo-gateway-api.yaml's ref.tag so both clouds run one Gateway API surface"
  type        = string
  default     = "v1.6.1"
}
