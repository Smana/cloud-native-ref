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

# --- Google-issued identities (not GKE ServiceAccounts) ----------------------
#
# Two things on GCP need to reach AWS with a token Google signs directly, not
# through the GKE issuer above: the OpenBao standby VM (a Compute Engine
# identity token, to use the AWS KMS seal) and the Storage Transfer service
# agent (to read the S3 snapshot bucket). Both trust the same
# `accounts.google.com` provider and are pinned by subject.

variable "gcp_openbao_standby_sa_unique_id" {
  description = "Unique ID of the openbao-node service account (opentofu/gcp/openbao/lineage output openbao_node_sa_unique_id). Empty skips the standby-seal role."
  type        = string
  default     = ""
}

variable "gcp_transfer_agent_subject_id" {
  description = "Subject ID of the project's Storage Transfer service agent (opentofu/gcp/openbao/lineage output transfer_agent_subject_id). Empty skips the mirror role."
  type        = string
  default     = ""
}

variable "openbao_seal_key_alias" {
  description = "Alias of the multi-region OpenBao seal key (opentofu/aws/openbao/lineage). Granted through the kms:ResourceAliases condition, so the key need not exist when this stack applies."
  type        = string
  default     = "alias/openbao-seal"
}

variable "openbao_snapshot_bucket_name" {
  description = "The AWS lineage's snapshot bucket the mirror role may read"
  type        = string
  default     = "eu-west-3-ogenki-openbao-snapshot"
}

variable "openbao_snapshot_key_alias" {
  description = "Alias of the KMS key encrypting the snapshot bucket"
  type        = string
  default     = "alias/xplane-openbao-snapshot"
}
