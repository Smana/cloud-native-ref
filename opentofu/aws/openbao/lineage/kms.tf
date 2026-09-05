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
# No custom key policy. The default policy delegates to IAM, and grants on
# this key are identity policies: this stack's own drill role names it by
# exact ARN, since this stack creates the key, while a role defined in a
# stack that does NOT create the key (e.g. the standby-seal role in
# opentofu/shared/aws-gcp-federation) has to resolve it by alias instead
# through a matching IAM condition. A key policy naming role ARNs would
# refuse to apply until those roles exist, and two of them live in other
# stacks.
#
# The Terramate destroy script gates on TM_LINEAGE_DESTROY, but that gate is
# only the front door: a bare `tofu destroy` (or `-target`) run directly in
# this stack directory -- the normal move when debugging state -- bypasses it
# entirely. prevent_destroy is the backstop for that path. This is the one
# resource in the whole repo that carries it, deliberately: losing this key
# makes every snapshot on both clouds permanently ciphertext, with no way to
# get it back, so destroying it is meant to take two separate, deliberate
# acts -- setting TM_LINEAGE_DESTROY=true AND removing this lifecycle block --
# not one. Do not add prevent_destroy anywhere else in this stack.
resource "aws_kms_key" "seal" {
  # checkov:skip=CKV2_AWS_64:Deliberately the DEFAULT key policy. An explicit one on this key is the highest-consequence mistake available in this stack: get it wrong and the key is unusable and undeletable (prevent_destroy above, and a key you cannot decrypt with is a key you cannot recover from), taking every snapshot on both clouds with it. Access is granted through IAM instead -- three roles, each scoped to Encrypt/Decrypt/DescribeKey by alias condition, in cluster/iam.tf, github-oidc.tf and shared/aws-gcp-federation.
  description             = "OpenBao seal key (lineage). Multi-region; replica in ${var.replica_region}"
  multi_region            = true
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
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
