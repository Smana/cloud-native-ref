variable "env" {
  description = "The environment of the EKS cluster"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "AWS Region"
  default     = "eu-west-3"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.region))
    error_message = "Region must be a valid AWS region format (e.g., eu-west-3)."
  }
}

# EKS
variable "name" {
  description = "Name of the EKS cluster to be created"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9]$", var.name)) && length(var.name) <= 100
    error_message = "Cluster name must start with a letter, contain only alphanumeric characters and hyphens, end with alphanumeric character, and be <= 100 characters."
  }
}

variable "kubernetes_version" {
  description = "k8s cluster version"
  default     = "1.33"
  type        = string

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.kubernetes_version))
    error_message = "Kubernetes version must be between 1.28 and 1.39 (format: 1.XX)."
  }
}

variable "enable_ssm" {
  description = "If true, allow to connect to the instances using AWS Systems Manager"
  type        = bool
  default     = false
}

variable "iam_role_additional_policies" {
  description = "Additional policies to be added to the IAM role"
  type        = map(string)
  default     = {}
}

variable "identity_providers" {
  description = "Map of cluster identity provider configurations to enable for the cluster."
  type        = any
  default     = {}
}

variable "cilium_version" {
  description = "Cilium cluster version"
  default     = "1.18.2"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter version"
  default     = "1.7.1"
  type        = string
}

variable "karpenter_limits" {
  description = "Define limits for Karpenter per node pool."
  type = map(object(
    {
      cpu    = optional(number, 50),
      memory = optional(string, "50Gi")
    }
    )
  )
}

variable "ebs_csi_driver_chart_version" {
  description = "EBS CSI Driver Helm chart version"
  default     = "2.39.0"
  type        = string
}

variable "gateway_api_version" {
  description = "Gateway API CRDs version"
  default     = "v1.3.0"
  type        = string
}

# Flux
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

variable "flux_operator_version" {
  description = "Flux Operator version"
  default     = "0.30.0"
  type        = string
}

variable "enable_flux_image_update_automation" {
  description = "Enable Flux image update automation"
  default     = false
  type        = bool
}

variable "flux_sync_repository_url" {
  description = "The repository URL to sync with Flux"
  type        = string

  validation {
    condition     = can(regex("^https://github\\.com/.+/.+\\.git$", var.flux_sync_repository_url))
    error_message = "Repository URL must be a valid GitHub HTTPS URL ending with .git."
  }
}

variable "flux_git_ref" {
  description = "Git branch or tag in the format refs/heads/main or refs/tags/v1.0.0"
  type        = string
  default     = "refs/heads/main"

  validation {
    condition     = can(regex("^refs/(heads|tags)/.+$", var.flux_git_ref))
    error_message = "Git ref must be in format refs/heads/branch-name or refs/tags/tag-name."
  }
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
