# GitHub Actions -> AWS, for the weekly restore drill only.
#
# The drill starts an OpenBao with the lineage seal, restores the newest
# snapshot and asserts the PKI issuer answers. It therefore needs the seal key
# (encrypt at init, decrypt to unwrap), the bucket, and the bucket's key --
# and nothing else. In particular it does NOT get the recovery keys: the drill
# proves restorability through unauthenticated endpoints, and a CI runner
# holding the material that mints a root token would be a standing exposure.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

data "aws_iam_policy_document" "drill_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the scheduled/dispatched workflow on main. A pull request from a
    # fork carries a different sub and is refused.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "drill" {
  name               = var.drill_role_name
  description        = "Assumed by .github/workflows/openbao-restore-drill.yml to restore the newest OpenBao snapshot into a throwaway node"
  assume_role_policy = data.aws_iam_policy_document.drill_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "drill" {
  # By alias, not by ARN, in every region: the seal key is multi-region and
  # the drill may run against either copy. kms:ResourceAliases is multivalued,
  # hence ForAnyValue.
  statement {
    sid    = "SealAndBucketKeysByAlias"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = [var.seal_key_alias, var.snapshot_key_alias]
    }
  }

  statement {
    sid     = "ReadSnapshots"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.snapshot.arn,
      "${aws_s3_bucket.snapshot.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "drill" {
  name   = "openbao-restore-drill"
  role   = aws_iam_role.drill.id
  policy = data.aws_iam_policy_document.drill.json
}
