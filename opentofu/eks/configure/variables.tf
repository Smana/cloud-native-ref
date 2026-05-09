variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "eu-west-3"
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  # Default mirrors `cilium_version` in opentofu/config.tm.hcl. The
  # global Terramate generator passes -var=cilium_version=... at run
  # time, so the local default is only consulted when running
  # `tofu plan` directly in this stack — keep the two in sync to
  # avoid surprises in that path.
  default = "1.19.0"
}

variable "flux_operator_version" {
  description = "Flux Operator Helm chart version"
  type        = string
  default     = "0.48.0"
}

variable "flux_instance_version" {
  description = "Flux Instance Helm chart version"
  type        = string
  default     = "0.48.0"
}

variable "flux_sync_url" {
  description = "Git repository URL for Flux sync"
  type        = string
}

variable "flux_git_ref" {
  description = "Git reference (branch/tag) for Flux sync"
  type        = string
  default     = "refs/heads/main"
}
