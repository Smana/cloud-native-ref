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

output "snapshot_bucket_name" {
  description = "Raft snapshot bucket"
  value       = aws_s3_bucket.snapshot.bucket
}

output "snapshot_bucket_arn" {
  description = "Raft snapshot bucket ARN, for policies in other stacks"
  value       = aws_s3_bucket.snapshot.arn
}

output "drill_role_arn" {
  description = "Set this as the AWS_DRILL_ROLE_ARN repository variable for the drill workflow"
  value       = aws_iam_role.drill.arn
}
