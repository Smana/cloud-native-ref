variable "project_id" {
  description = "GCP project ID"
  type        = string
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
}

variable "flux_operator_version" {
  description = "Flux Operator chart version. Shared with AWS"
  type        = string
}

variable "flux_instance_version" {
  description = "Flux Instance chart version. Shared with AWS"
  type        = string
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
