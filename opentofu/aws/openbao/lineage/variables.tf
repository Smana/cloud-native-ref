variable "region" {
  description = "Primary AWS region: where the seal key's primary and the snapshot bucket live"
  type        = string
  default     = "eu-west-3"
}

variable "replica_region" {
  description = "Second AWS region holding a replica of the multi-region seal key. Must differ from region."
  type        = string
  default     = "eu-west-1"

  validation {
    condition     = var.replica_region != var.region
    error_message = "replica_region must differ from region, or the replica buys nothing."
  }
}

variable "seal_key_alias" {
  description = "Alias of the seal key, in both regions. The cluster stack, the standby role and the drill role all reference the key through this alias."
  type        = string
  default     = "alias/openbao-seal"
}

variable "snapshot_bucket_name" {
  description = "S3 bucket holding raft snapshots. Empty derives <region>-ogenki-openbao-snapshot, the name the Crossplane-managed bucket already has."
  type        = string
  default     = ""
}

variable "snapshot_key_alias" {
  description = "Alias of the KMS key encrypting the snapshot bucket. Kept at the Crossplane-era name so the imported key keeps its alias."
  type        = string
  default     = "alias/xplane-openbao-snapshot"
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose main-branch workflows may assume the drill role"
  type        = string
  default     = "Smana/cloud-native-ref"
}

variable "drill_role_name" {
  description = "IAM role the weekly restore drill assumes from GitHub Actions"
  type        = string
  default     = "openbao-restore-drill"
}

variable "tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    project = "cloud-native-ref"
    owner   = "Smana"
    app     = "openbao"
  }
}
