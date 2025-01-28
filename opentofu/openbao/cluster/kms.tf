resource "aws_kms_key" "openbao" {
  description             = "OpenBao unseal key"
  deletion_window_in_days = 10

  tags = {
    Name = "openbao-kms-unseal-${local.name}"
  }
}
