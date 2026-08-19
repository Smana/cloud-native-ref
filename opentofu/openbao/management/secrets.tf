# Get the OpenBao root token from AWS Secrets Manager
data "aws_secretsmanager_secret_version" "openbao_root_token_secret" {
  secret_id = var.openbao_root_token_secret_id
}

# Get the root CA bundle from AWS Secrets Manager
data "aws_secretsmanager_secret" "root_ca" {
  name = var.root_ca_secret_name
}

data "aws_secretsmanager_secret_version" "root_ca" {
  secret_id = data.aws_secretsmanager_secret.root_ca.id
}

# Store AppRole credentials in AWS Secrets Manager
resource "aws_secretsmanager_secret" "cert_manager_approle_credentials" {
  name                    = var.cert_manager_approle_secret_name
  recovery_window_in_days = 0
}

# Generate a new secret ID for the AppRole
resource "vault_approle_auth_backend_role_secret_id" "cert_manager" {
  namespace = vault_auth_backend.approle_pki.namespace
  backend   = vault_auth_backend.approle_pki.path
  role_name = vault_approle_auth_backend_role.cert_manager.role_name
}

resource "aws_secretsmanager_secret_version" "cert_manager_approle_credentials" {
  secret_id = aws_secretsmanager_secret.cert_manager_approle_credentials.id
  secret_string = jsonencode({
    cert_manager_approle_id     = vault_approle_auth_backend_role.cert_manager.role_id
    cert_manager_approle_secret = vault_approle_auth_backend_role_secret_id.cert_manager.secret_id
  })
}

# Snapshot agent AppRole
# ----------------------
# This used to be a manual `bao write ... /secret-id` plus a hand-built
# `aws secretsmanager create-secret`, documented in docs/backup_restore.md.
# A credential created by hand outside the stack that manages every other
# credential drifts by construction - and it is the one the disaster-recovery
# job depends on.
locals {
  openbao_address      = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.region) : var.snapshot_bucket_name
}

resource "aws_secretsmanager_secret" "snapshot_approle_credentials" {
  name                    = var.snapshot_approle_secret_name
  recovery_window_in_days = 0
}

resource "vault_approle_auth_backend_role_secret_id" "snapshot" {
  namespace = vault_auth_backend.approle_admin.namespace
  backend   = vault_auth_backend.approle_admin.path
  role_name = vault_approle_auth_backend_role.snapshot.role_name
}

resource "aws_secretsmanager_secret_version" "snapshot_approle_credentials" {
  secret_id = aws_secretsmanager_secret.snapshot_approle_credentials.id
  secret_string = jsonencode({
    APPROLE_ROLE_ID   = vault_approle_auth_backend_role.snapshot.role_id
    APPROLE_SECRET_ID = vault_approle_auth_backend_role_secret_id.snapshot.secret_id
    VAULT_ADDR        = local.openbao_address
    BUCKET_NAME       = local.snapshot_bucket_name
    # Consumed only by `openbao-snapshot.sh restore`, which is an operator
    # action run with operator credentials. The CronJob's EKS Pod Identity role
    # intentionally has no secretsmanager access - a daily backup pod that can
    # read the material for regenerating a root token is a privilege
    # escalation, not a convenience.
    RECOVERY_KEYS_SECRET_ID = var.recovery_keys_secret_name
  })
}
