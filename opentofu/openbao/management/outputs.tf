output "cert_manager_approle_credentials_secret_arn" {
  description = "The ARN of the AWS Secrets Manager secret containing the cert-manager AppRole credentials"
  value       = aws_secretsmanager_secret.cert_manager_approle_credentials.arn
}

output "cert_manager_approle_role_id" {
  description = "The role ID of the cert-manager AppRole"
  value       = vault_approle_auth_backend_role.cert_manager.role_id
}

output "admin_credentials_secret_name" {
  description = "AWS Secrets Manager entry holding the generated operator password. Retrieve with: aws secretsmanager get-secret-value --secret-id <this> --query SecretString --output text | jq"
  value       = aws_secretsmanager_secret.admin_credentials.name
}

output "operator_login_command" {
  description = "How to log in as a human operator. One login, in the root namespace, carrying both the admin and pki-admin policies."
  value       = "bao login -method=userpass username=${var.admin_username}"
}
