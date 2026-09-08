variable "project_id" {
  description = "GCP project holding OpenBao and its snapshot bucket"
  type        = string
}

variable "region" {
  description = "GCP region for the bucket"
  type        = string
  default     = "europe-west4"
}

variable "snapshot_bucket_name" {
  description = "GCS bucket for raft snapshots and the mirror of the AWS bucket. Empty derives <project_id>-ogenki-openbao-snapshot, the name the Crossplane bucket already has (project-prefixed: GCS names are global, and the Crossplane IAM condition keyed on that prefix)."
  type        = string
  default     = ""
}

variable "aws_snapshot_bucket_name" {
  description = "The AWS lineage's snapshot bucket, pulled by the Storage Transfer job"
  type        = string
  default     = "eu-west-3-ogenki-openbao-snapshot"
}

variable "aws_mirror_role_arn" {
  description = "ARN of the AWS role the Storage Transfer service agent assumes to read the S3 bucket (opentofu/shared/aws-gcp-federation, `openbao-snapshot-mirror`). Empty disables the transfer job -- the federation stack needs this stack's transfer_agent_subject_id output first, so the two are applied in two passes."
  type        = string
  default     = ""
}

variable "mirror_start_hour_utc" {
  description = "Hour (UTC) the daily mirror runs. One hour after the 04:00 UTC snapshot CronJob."
  type        = number
  default     = 5
}

variable "github_repository" {
  description = "GitHub repository (owner/name) whose workflows may impersonate the drill service account"
  type        = string
  default     = "Smana/cloud-native-ref"
}
