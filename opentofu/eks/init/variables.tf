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
  default     = "1.36"
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

# Gateway API CRDs, Flux bootstrap secrets, and the public/private domain names
# are consumed by the cluster-internal resources, which now live in eks/configure
# (the stage that runs against an already-created cluster). Their variables were
# moved there along with the resources.

# Note: Flux configuration (version, sync URL, git ref) is now managed via Terramate globals
# in opentofu/config.tm.hcl and Helm values in opentofu/eks/helm_values/flux-instance.yaml

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
