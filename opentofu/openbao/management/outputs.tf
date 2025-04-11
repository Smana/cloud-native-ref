output "cert_manager_approle_credentials_secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret containing the cert-manager AppRole credentials"
  value       = aws_secretsmanager_secret.cert_manager_approle_credentials.arn
}

output "cert_manager_approle_role_id" {
  description = "The role ID of the cert-manager AppRole"
  value       = vault_approle_auth_backend_role.cert_manager.role_id
}
