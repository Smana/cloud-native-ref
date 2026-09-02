# Get the OpenBao root token from AWS Secrets Manager
data "aws_secretsmanager_secret_version" "openbao_root_token_secret" {
  secret_id = var.openbao_root_token_secret_id
}

# The openssl-made intermediate: certificate AND private key, as one pem_bundle
# under the `bundle` key. Written by the offline ceremony, never by this stack.
# The ROOT key is deliberately absent from AWS entirely.
data "aws_secretsmanager_secret_version" "intermediate_ca" {
  secret_id = var.intermediate_ca_secret_name
}

# Human operator password
# -----------------------
# Generated here rather than chosen by hand, and published to Secrets Manager so
# the operator can retrieve it. One password now: collapsing the platform into
# the root namespace means one login carrying both the `admin` and `pki-admin`
# policies, where the old `admin` / `admin/pki` split forced one per namespace.
#
# This does land in the state file, as does the root token, the only other
# credential this stack manages. The provider's write-only `password_wo`
# attribute would avoid that, but it needs write-only attribute support, so it
# is deliberately not used here.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "aws_secretsmanager_secret" "admin_credentials" {
  #checkov:skip=CKV_AWS_149:AWS-managed key, matching the AVD-AWS-0098 decision recorded in .trivyignore.yaml. A CMK would add key-policy access control at the cost of another key to manage and a kms:Decrypt grant on every consumer. Revisit if this platform stops being ephemeral.
  #checkov:skip=CKV2_AWS_57:Rotation happens by re-running this stack, which generates a fresh password. A Secrets Manager rotation Lambda cannot rotate an OpenBao userpass credential - it has no way to talk to OpenBao.
  name                    = var.admin_credentials_secret_name
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "admin_credentials" {
  secret_id = aws_secretsmanager_secret.admin_credentials.id
  secret_string = jsonencode({
    username = var.admin_username
    password = random_password.admin.result
    # Root namespace, so no namespace argument is needed when logging in.
    address = local.openbao_address
  })
}

locals {
  openbao_address = var.openbao_domain_name == "" ? format("https://bao.%s:8200", var.domain_name) : var.openbao_domain_name
}
