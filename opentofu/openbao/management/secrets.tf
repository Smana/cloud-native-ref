# Get the root CA bundle from AWS Secrets Manager
data "aws_secretsmanager_secret" "root_ca" {
  name = var.root_ca_secret_name
}

data "aws_secretsmanager_secret_version" "root_ca" {
  secret_id = data.aws_secretsmanager_secret.root_ca.id
}

# Store AppRole credentials in AWS Secrets Manager
resource "aws_secretsmanager_secret" "approle_credentials" {
  name = var.cert_manager_approle_secret_name
}

# Generate a new secret ID for the AppRole
resource "vault_approle_auth_backend_role_secret_id" "cert_manager" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.cert_manager.role_name
}

resource "aws_secretsmanager_secret_version" "approle_credentials" {
  secret_id = aws_secretsmanager_secret.approle_credentials.id
  secret_string = jsonencode({
    cert_manager_approle_id     = vault_approle_auth_backend_role.cert_manager.role_id
    cert_manager_approle_secret = vault_approle_auth_backend_role_secret_id.cert_manager.secret_id
  })
}
