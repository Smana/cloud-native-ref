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
    # fork carries a different sub and is refused. An exact-match condition,
    # not a pattern-match one: the value has no wildcard today, and the
    # exact-match test keeps it that way -- a later edit to something like
    # refs/heads/* would silently widen the trust under a pattern-match
    # condition without anyone touching an operator.
    condition {
      test     = "StringEquals"
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
  # Exact ARNs, not the alias-plus-condition indirection used by grants
  # written in stacks that do NOT create the key (e.g. the standby-seal role
  # in opentofu/shared/aws-gcp-federation, which has to resolve the key by
  # its alias at grant time): this stack creates both keys, so it can name
  # them directly. The seal key ARN uses the bare key/<id> form with a region
  # wildcard: a multi-region key shares its key ID across regions, so this
  # one ARN matches both the primary in var.region and the replica in
  # var.replica_region.
  #
  # Actions are the whole requirement for what the drill does: an `awskms`
  # seal wraps a locally generated key with kms:Encrypt and unwraps with
  # kms:Decrypt; SSE-KMS GetObject needs only kms:Decrypt. Nothing here asks
  # KMS to generate that data key itself, and nothing here moves ciphertext
  # to a different key, so neither of those two other action families
  # belongs in this policy.
  statement {
    sid    = "SealAndBucketKeys"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [
      "arn:aws:kms:*:${data.aws_caller_identity.this.account_id}:key/${aws_kms_key.seal.key_id}",
      aws_kms_key.snapshot.arn,
    ]
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
