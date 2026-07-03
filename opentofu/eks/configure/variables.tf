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
  default = "1.19.5"
}

variable "flux_operator_version" {
  description = "Flux Operator Helm chart version"
  type        = string
  default     = "0.53.0"
}

variable "flux_instance_version" {
  description = "Flux Instance Helm chart version"
  type        = string
  default     = "0.53.0"
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

variable "env" {
  description = "The environment of the EKS cluster"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "gateway_api_version" {
  description = "Gateway API CRDs version — must match flux/sources/gitrepo-gateway-api.yaml ref"
  type        = string
  default     = "v1.6.0"
}

variable "private_domain_name" {
  description = "Private domain name for internal services (e.g., priv.cloud.ogenki.io)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.private_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "public_domain_name" {
  description = "Public domain name for internet-facing services (e.g., cloud.ogenki.io)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.public_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "github_app_secret_name" {
  type        = string
  description = "SecretsManager name from where to retrieve the Github App information. ref: https://fluxcd.io/flux/components/source/gitrepositories/#github"
  default     = "github/flux-app"
  sensitive   = true
}

variable "cert_manager_approle_secret_name" {
  type        = string
  description = "SecretsManager name from where to retrieve the cert-manager approle information."
  default     = "openbao/approles/cert-manager"
  sensitive   = true
}
