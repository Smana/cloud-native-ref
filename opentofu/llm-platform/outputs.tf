output "filesystem_id" {
  description = "S3 Files filesystem ID — referenced by the EFS CSI driver PV manifest under spec.csi.volumeHandle"
  value       = aws_s3files_file_system.models.id
}

output "filesystem_arn" {
  description = "S3 Files filesystem ARN"
  value       = aws_s3files_file_system.models.arn
}

output "access_point_id" {
  description = "Shared access point ID — combined with filesystem_id into volumeHandle: s3files:<fs>::<ap>"
  value       = aws_s3files_access_point.shared.id
}

output "access_point_arn" {
  description = "Shared access point ARN"
  value       = aws_s3files_access_point.shared.arn
}

output "csi_driver_role_arn" {
  description = "IAM role ARN consumed by the EFS CSI driver controller via EKS Pod Identity"
  value       = aws_iam_role.csi_driver.arn
}

output "volume_handle" {
  description = "PV-ready volumeHandle string for the InferenceService composition's PV manifest"
  value       = "s3files:${aws_s3files_file_system.models.id}::${aws_s3files_access_point.shared.id}"
}
