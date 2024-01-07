#tfsec:ignore:aws-kms-auto-rotate-keys
resource "aws_kms_key" "vault" {
  description             = "Vault unseal key"
  deletion_window_in_days = 10

  tags = {
    Name = "vault-kms-unseal-${local.name}"
  }
}
