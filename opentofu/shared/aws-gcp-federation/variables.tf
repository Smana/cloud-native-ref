variable "aws_region" {
  description = "AWS region for the provider. Route53 is global, but the SDK needs a region to compute credential scope."
  type        = string
  default     = "eu-west-3"
}

variable "gcp_project_id" {
  description = "GCP project holding the GKE cluster whose tokens AWS will trust"
  type        = string
  default     = "ogenki-435905"
}

variable "gcp_cluster_location" {
  description = "GKE cluster location (zone). Part of the OIDC issuer URL."
  type        = string
  default     = "europe-west4-a"
}

variable "gcp_cluster_name" {
  description = "GKE cluster name. Part of the OIDC issuer URL, which is why renaming the cluster invalidates this federation -- see the note in main.tf."
  type        = string
  default     = "gcp-0"
}

variable "public_domain_name" {
  description = "Public zone the federated role may change records in. Looked up, never managed here."
  type        = string
  default     = "cloud.ogenki.io"
}

variable "trusted_service_accounts" {
  description = "Kubernetes ServiceAccounts allowed to assume the role, as `<namespace>/<name>`. Each becomes one `system:serviceaccount:<ns>:<sa>` subject in the trust policy. Keep this list minimal -- it is the entire membership of the cross-cloud trust."
  type        = list(string)
  default = [
    "security/cert-manager",
    "kube-system/external-dns-public",
  ]

  validation {
    condition     = alltrue([for sa in var.trusted_service_accounts : can(regex("^[a-z0-9-]+/[a-z0-9-]+$", sa))])
    error_message = "Each entry must be exactly `<namespace>/<name>`."
  }
}
