resource "aws_iam_instance_profile" "this" {
  name = local.name
  role = aws_iam_role.this.name
  tags = var.tags
}

resource "aws_iam_role" "this" {
  name = local.name
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
}

# enable AWS Systems Manager service core functionality
resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# For the raft auto_join discovery.
#
# This used to be the AmazonEC2ReadOnlyAccess managed policy, which also grants
# ec2:DescribeLaunchTemplateVersions - i.e. read access to this instance's own
# user_data, and to every other launch template in the account. auto_join needs
# exactly one call.
data "aws_iam_policy_document" "openbao_autojoin" {
  statement {
    sid       = "RaftAutoJoinDiscovery"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"] # ec2:DescribeInstances does not support resource-level permissions
  }
}

resource "aws_iam_role_policy" "openbao_autojoin" {
  name   = "${local.name}-raft-autojoin"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.openbao_autojoin.json
}

# For fetching the server TLS material at boot (see scripts/startup_script.sh).
# Scoped to the single secret holding this cluster's certificate.
data "aws_iam_policy_document" "openbao_certificates" {
  statement {
    sid       = "ReadServerCertificate"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.openbao_certificates.arn]
  }
}

resource "aws_iam_role_policy" "openbao_certificates" {
  name   = "${local.name}-server-certificate"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.openbao_certificates.json
}


# For the auto unseal using AWS KMS
#
# Three actions, which is the whole KMS surface of an `awskms` seal:
# DescribeKey when it configures the seal, Encrypt to wrap the barrier key,
# Decrypt to unwrap it. The same three the drill role
# (opentofu/aws/openbao/lineage/github-oidc.tf) and the GCP standby-seal role
# (opentofu/shared/aws-gcp-federation/google-identity.tf) carry -- all three
# grants agree, because all three drive the identical wrapper.
#
# The non-obvious half, and the first thing a reviewer doubts:
# kms:GenerateDataKey* is NOT needed, even though this is envelope encryption.
# wrapping.EnvelopeEncrypt generates the 32-byte data key IN-PROCESS
# (uuid.GenerateRandomBytes(32), then a local AES-GCM seal) and sends only that
# key to kms:Encrypt -- the DEK never leaves the process for KMS to mint, so the
# API that mints one is never called. Nothing re-wraps ciphertext under a
# different key either, so kms:ReEncrypt* has no caller. Both were in the
# Vault-era convention this grant was copied from, and both are removed here.
# OpenBao's own awskms seal page says the same: "OpenBao needs the following
# permissions on the KMS key: kms:Encrypt, kms:Decrypt, kms:DescribeKey."
#
# Steady state adds no action either: the seal health check runs one
# Encrypt->Decrypt round trip every ten minutes, both already granted.
data "aws_iam_policy_document" "openbao-kms-unseal" {
  statement {
    sid       = "VaultKMSUnseal"
    effect    = "Allow"
    resources = [data.aws_kms_alias.seal.target_key_arn]

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:DescribeKey"
    ]
  }
}

resource "aws_iam_role_policy" "openbao-kms-unseal" {
  name   = "${local.name}-kms-unseal"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.openbao-kms-unseal.json
}
