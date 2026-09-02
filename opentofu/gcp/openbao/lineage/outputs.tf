output "snapshot_bucket_name" {
  description = "GCS snapshot bucket, also the mirror target"
  value       = google_storage_bucket.snapshot.name
}

output "openbao_node_sa_email" {
  description = "The node's service account. Consumed by opentofu/gcp/openbao/cluster through remote state."
  value       = google_service_account.openbao_node.email
}

output "openbao_node_sa_unique_id" {
  description = "Set this as gcp_openbao_standby_sa_unique_id in opentofu/shared/aws-gcp-federation/variables.tfvars: the AWS seal role trusts this subject."
  value       = google_service_account.openbao_node.unique_id
}

output "transfer_agent_subject_id" {
  description = "Set this as gcp_transfer_agent_subject_id in opentofu/shared/aws-gcp-federation/variables.tfvars: the AWS mirror role trusts this subject."
  value       = data.google_storage_transfer_project_service_account.default.subject_id
}

output "drill_workload_identity_provider" {
  description = "Set this as the GCP_DRILL_WIF_PROVIDER repository variable for the drill workflow"
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "drill_service_account_email" {
  description = "Set this as the GCP_DRILL_SERVICE_ACCOUNT repository variable for the drill workflow"
  value       = google_service_account.openbao_drill.email
}
