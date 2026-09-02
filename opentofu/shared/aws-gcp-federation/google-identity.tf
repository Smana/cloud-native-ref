# AWS trusts tokens Google signs for two specific principals.
#
# This is a SECOND OIDC provider next to the GKE one in main.tf, and it is a
# different kind of token: `accounts.google.com` issues identity tokens for
# Google service accounts (a Compute Engine VM asking the metadata server, or a
# Google-managed service agent), where the GKE provider validates Kubernetes
# ServiceAccount tokens. Same pattern -- no material at rest, short-lived
# credentials from STS -- different issuer.
#
# Claim mapping AWS uses for Google tokens: `accounts.google.com:sub` is the
# service account's unique ID; `accounts.google.com:oaud` is the token's `aud`;
# `accounts.google.com:aud` is `azp`. Each role pins `sub` and `oaud`.
data "aws_caller_identity" "this" {}

data "tls_certificate" "google" {
  url = "https://accounts.google.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "google" {
  url = "https://accounts.google.com"
  # Every `aud` a trusted token may carry. The standby VM requests
  # sts.amazonaws.com; Storage Transfer's federated-identity tokens carry the
  # service agent's own subject ID as their audience.
  client_id_list  = compact(["sts.amazonaws.com", var.gcp_transfer_agent_subject_id])
  thumbprint_list = [data.tls_certificate.google.certificates[0].sha1_fingerprint]
}

# --- openbao-standby-seal ------------------------------------------------------
#
# Lets the GCP OpenBao node use the AWS multi-region seal key, so a snapshot
# taken under that seal restores on GCP during an AWS regional outage
# (design scenario A). The node fetches a Compute Engine identity token with
# audience sts.amazonaws.com every 50 minutes and the awskms seal exchanges it
# through the SDK's web-identity credential provider.
data "aws_iam_policy_document" "standby_seal_assume" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.google.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.gcp_openbao_standby_sa_unique_id]
    }
  }
}

resource "aws_iam_role" "standby_seal" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  name               = "openbao-standby-seal"
  description        = "Assumed by the GCP OpenBao node (openbao-node service account) to use the AWS multi-region seal key"
  assume_role_policy = data.aws_iam_policy_document.standby_seal_assume[0].json
}

data "aws_iam_policy_document" "standby_seal" {
  statement {
    sid    = "SealKeyByAlias"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    # Every region: the standby names the replica region's copy.
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.openbao_seal_key_alias]
    }
  }
}

resource "aws_iam_role_policy" "standby_seal" {
  count = var.gcp_openbao_standby_sa_unique_id == "" ? 0 : 1

  name   = "openbao-seal-key"
  role   = aws_iam_role.standby_seal[0].id
  policy = data.aws_iam_policy_document.standby_seal.json
}

# --- openbao-snapshot-mirror ---------------------------------------------------
#
# Lets Google's Storage Transfer Service read the AWS snapshot bucket to mirror
# it into GCS (opentofu/gcp/openbao/lineage/transfer.tf). Read-only on one
# bucket, plus decrypt on that bucket's key.
data "aws_iam_policy_document" "mirror_assume" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.google.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:oaud"
      values   = [var.gcp_transfer_agent_subject_id]
    }

    condition {
      test     = "StringEquals"
      variable = "accounts.google.com:sub"
      values   = [var.gcp_transfer_agent_subject_id]
    }
  }
}

resource "aws_iam_role" "mirror" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  name               = "openbao-snapshot-mirror"
  description        = "Assumed by the GCP Storage Transfer service agent to mirror the OpenBao snapshot bucket into GCS"
  assume_role_policy = data.aws_iam_policy_document.mirror_assume[0].json
}

data "aws_iam_policy_document" "mirror" {
  statement {
    sid     = "ReadSnapshots"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
    resources = [
      "arn:aws:s3:::${var.openbao_snapshot_bucket_name}",
      "arn:aws:s3:::${var.openbao_snapshot_bucket_name}/*",
    ]
  }

  statement {
    sid       = "DecryptSnapshotObjects"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.openbao_snapshot_key_alias]
    }
  }
}

resource "aws_iam_role_policy" "mirror" {
  count = var.gcp_transfer_agent_subject_id == "" ? 0 : 1

  name   = "openbao-snapshot-read"
  role   = aws_iam_role.mirror[0].id
  policy = data.aws_iam_policy_document.mirror.json
}
