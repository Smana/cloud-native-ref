#trivy:ignore:AVD-AWS-0104
resource "aws_kms_key" "openbao" {
  description             = "OpenBao unseal key"
  deletion_window_in_days = 10

  # Rotation is transparent for an awskms seal: KMS retains every previous
  # backing key and picks the right one on Decrypt, so the encrypted barrier key
  # stays readable across rotations. There was no reason to carry the
  # AVD-AWS-0065 suppression this used to have.
  enable_key_rotation = true

  tags = {
    Name = "openbao-kms-unseal-${local.name}"
  }
}
