#trivy:ignore:AVD-AWS-0104 trivy:ignore:AVD-AWS-0065
resource "aws_kms_key" "openbao" {
  description             = "OpenBao unseal key"
  deletion_window_in_days = 10

  tags = {
    Name = "openbao-kms-unseal-${local.name}"
  }
}
