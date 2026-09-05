output "seal_key_arn" {
  description = "Primary seal key ARN"
  value       = aws_kms_key.seal.arn
}

output "seal_key_id" {
  description = "Multi-region key ID (mrk-...), identical in both regions. What a standby's awskms seal stanza names."
  value       = aws_kms_key.seal.key_id
}

output "seal_key_alias" {
  description = "Alias present in both regions"
  value       = aws_kms_alias.seal.name
}

output "replica_region" {
  description = "Where the replica key lives"
  value       = var.replica_region
}

# Both bucket outputs are for a HUMAN running `tofu output`, not for another
# stack. Nothing in opentofu/ reads this stack's remote state -- there is no
# `data "terraform_remote_state"` pointed at it anywhere -- and the ARN's
# description used to say "for policies in other stacks", which promised a
# consumer that has never existed.
#
# They are still worth keeping, because the name is COMPUTED rather than
# configured: s3.tf derives it as "<region>-ogenki-openbao-snapshot" whenever
# var.snapshot_bucket_name is empty, which is the default. So `tofu output` is the
# only way to read the live value without re-deriving the format string by hand --
# and two places restate that value literally and have to be kept in step with it.
#
# Restating rather than wiring up remote state is a deliberate repo-wide choice,
# not an oversight here; opentofu/gcp/gke/configure/variables.tfvars records the
# reasoning.
output "snapshot_bucket_name" {
  description = "Raft snapshot bucket. Computed from var.region unless var.snapshot_bucket_name is set. Restated literally as global.snapshot_bucket_name in opentofu/config.tm.hcl and as var.openbao_snapshot_bucket_name in opentofu/shared/aws-gcp-federation, so a change here has to be copied to both."
  value       = aws_s3_bucket.snapshot.bucket
}

output "snapshot_bucket_arn" {
  description = "Raft snapshot bucket ARN, for writing a bucket policy by hand. No stack reads it: the one policy that needs the ARN -- the mirror role in opentofu/shared/aws-gcp-federation -- builds it from the bucket NAME it is handed."
  value       = aws_s3_bucket.snapshot.arn
}

output "drill_role_arn" {
  description = "Set this as the AWS_DRILL_ROLE_ARN repository variable for the drill workflow"
  value       = aws_iam_role.drill.arn
}
