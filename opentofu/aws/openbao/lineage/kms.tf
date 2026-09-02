# The seal key. This is THE asset: a snapshot without it is ciphertext.
#
# It used to live in opentofu/aws/openbao/cluster/kms.tf with a 10-day deletion
# window, so every rebuild minted a new key and every snapshot taken under the
# previous one became unreadable. Harmless while dev mode ran `file` storage
# and never took a snapshot; fatal for anything that restores one.
#
# Multi-region: the primary here, one replica in var.replica_region. A replica
# shares key material and key ID (`mrk-...`) with the primary, so ciphertext
# wrapped in eu-west-3 unwraps in eu-west-1. That is what lets a GCP standby,
# or a CI drill, restore a snapshot during a eu-west-3 outage.
#
# No custom key policy. The default policy delegates to IAM, and every grant
# on this key is an identity policy using the kms:ResourceAliases condition --
# a key policy naming role ARNs would refuse to apply until those roles exist,
# and two of them live in other stacks.
#trivy:ignore:AVD-AWS-0104
resource "aws_kms_key" "seal" {
  description             = "OpenBao seal key (lineage). Multi-region; replica in ${var.replica_region}"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "seal" {
  name          = var.seal_key_alias
  target_key_id = aws_kms_key.seal.key_id
}

resource "aws_kms_replica_key" "seal" {
  provider                = aws.replica
  description             = "OpenBao seal key (lineage) -- replica of ${var.region}"
  primary_key_arn         = aws_kms_key.seal.arn
  deletion_window_in_days = 30
  tags                    = var.tags
}

# Same alias name in the replica region, so a consumer only needs to know the
# alias and the region it is in.
resource "aws_kms_alias" "seal_replica" {
  provider      = aws.replica
  name          = var.seal_key_alias
  target_key_id = aws_kms_replica_key.seal.key_id
}
