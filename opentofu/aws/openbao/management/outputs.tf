output "admin_credentials_secret_name" {
  description = "AWS Secrets Manager entry holding the generated operator password. Retrieve with: aws secretsmanager get-secret-value --secret-id <this> --query SecretString --output text | jq"
  value       = aws_secretsmanager_secret.admin_credentials.name
}

output "operator_login_command" {
  description = "How to log in as a human operator. One login, in the root namespace, carrying both the admin and pki-admin policies."
  value       = "bao login -method=userpass username=${var.admin_username}"
}
