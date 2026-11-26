output "route53_role_arn" {
  description = "ARN the ClusterIssuer's route53 solver and external-dns-public assume"
  value       = aws_iam_role.route53.arn
}

output "oidc_issuer" {
  description = "The GKE issuer AWS trusts. Renaming or moving the cluster changes this and invalidates the provider."
  value       = local.oidc_issuer
}

output "public_zone_id" {
  description = "Hosted zone the role may change records in"
  value       = data.aws_route53_zone.public.zone_id
}

output "openbao_standby_seal_role_arn" {
  description = "Set as aws_seal_role_arn in opentofu/gcp/openbao/cluster/variables.tfvars for a standby deploy. Empty until gcp_openbao_standby_sa_unique_id is set."
  value       = length(aws_iam_role.standby_seal) == 0 ? "" : aws_iam_role.standby_seal[0].arn
}

output "openbao_snapshot_mirror_role_arn" {
  description = "Set as aws_mirror_role_arn in opentofu/gcp/openbao/lineage/variables.tfvars. Empty until gcp_transfer_agent_subject_id is set."
  value       = length(aws_iam_role.mirror) == 0 ? "" : aws_iam_role.mirror[0].arn
}

output "vertex_wif_audience" {
  description = "The external_account `audience` aws-0's model gateway presents. Set as gcp_vertex_wif_audience in opentofu/aws/eks/configure/variables.tfvars. Empty with vertex_federation_enabled off."
  value       = length(google_iam_workload_identity_pool_provider.aws) == 0 ? "" : "//iam.googleapis.com/projects/${data.google_project.vertex[0].number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.aws[0].workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.aws[0].workload_identity_pool_provider_id}"
}
