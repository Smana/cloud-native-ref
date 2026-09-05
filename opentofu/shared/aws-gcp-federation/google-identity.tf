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

# NO thumbprint_list, deliberately.
#
# It used to be `[data.tls_certificate.google.certificates[0].sha1_fingerprint]`,
# which pins the LEAF certificate of accounts.google.com -- a certificate Google
# rotates roughly every 90 days. Every rotation is unmanaged drift, and the
# 2026-09-05 deploy caught one mid-flight:
#
# (the two fingerprints below are PUBLIC certificate hashes, hence the pragmas --
# detect-secrets sees any high-entropy hex and cannot tell the difference)
#   ~ thumbprint_list = [
#       - "08745487e891c19e3078c1f2a07e452950ef36f6",  # pragma: allowlist secret
#       + "932bed339aa69212c89375b79304b475490b89a0",  # pragma: allowlist secret
#     ]
#
# Taking the last element instead is a trap rather than a fix: accounts.google.com
# serves its LEAF TWICE, first and last, so `certificates[length-1]` is the leaf
# again. The chain as served is leaf, WR2, GTS Root R1, leaf.
#
# The right answer is not to pin one at all. `thumbprint_list` is Optional and
# Computed in the AWS provider, and AWS does not use a thumbprint for IdPs whose
# root it already trusts -- Google among them; it validates against its own
# library of trusted CAs instead. Omitting it therefore leaves verification
# exactly as strong as before, removes a value that was never load-bearing, and
# stops terraform reporting a diff every time Google rotates a certificate.
#
# The data source that fed it is gone with it: its only consumer was this
# argument, and accounts.google.com's reachability is not in question. The GKE
# provider in main.tf keeps ITS data source, because there it doubles as a
# reachability check on a per-cluster issuer URL that can genuinely be wrong.
resource "aws_iam_openid_connect_provider" "google" {
  url = "https://accounts.google.com"
  # NOT simply "every `aud` a trusted token may carry" -- that reading of this
  # field is what broke the standby path, and it is worth spelling out because
  # nothing in the failure names it.
  #
  # AWS matches a Google token against this list on the AUTHORIZED PARTY (`azp`)
  # as well as the audience, and a GCE instance identity token's `azp` is the
  # service account's unique ID -- never the audience string it was minted for.
  # A list holding only "sts.amazonaws.com" therefore rejects the very token the
  # standby node presents:
  #
  #   Code: InvalidIdentityToken
  #   "The web identity token provided could not be validated."
  #
  # Measured 2026-09-05 from a throwaway GCE instance running as openbao-node,
  # printing its own claims next to the failure:
  #
  #   {"aud":"sts.amazonaws.com","azp":"110583515827251510802",
  #    "iss":"https://accounts.google.com","sub":"110583515827251510802"}
  #
  # Every condition in the trust policy below matched that token, and STS still
  # refused it. Adding the standby's unique ID here -- changing nothing else --
  # turned the same request into an assumed-role ARN. The thumbprint was ruled
  # out first: substituting each certificate of accounts.google.com's live chain
  # changed nothing.
  #
  # So this list holds, per federated principal, whichever claim AWS actually
  # matches -- the standby's SA unique ID, the Storage Transfer service agent's
  # subject ID -- plus sts.amazonaws.com for the audience itself.
  client_id_list = compact([
    "sts.amazonaws.com",
    var.gcp_transfer_agent_subject_id,
    var.gcp_openbao_standby_sa_unique_id,
  ])

}

# --- openbao-standby-seal ------------------------------------------------------
#
# Lets the GCP OpenBao node use the AWS multi-region seal key, so a snapshot
# taken under that seal restores on GCP during an AWS regional outage
# (design scenario A). The node fetches a Compute Engine identity token with
# audience sts.amazonaws.com every 15 minutes and the awskms seal exchanges it
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
  # Three actions, which is the whole KMS surface of an `awskms` seal:
  # DescribeKey when it configures the seal, Encrypt to wrap the barrier key,
  # Decrypt to unwrap it. Same three as the drill role in
  # opentofu/aws/openbao/lineage/github-oidc.tf and the AWS node's own seal role
  # in opentofu/aws/openbao/cluster/iam.tf -- all three grants now agree,
  # because all three drive the identical wrapper.
  #
  # The non-obvious half, and the first thing a reviewer doubts:
  # kms:GenerateDataKey* is NOT needed, even though this is envelope
  # encryption. wrapping.EnvelopeEncrypt generates the 32-byte data key
  # IN-PROCESS (uuid.GenerateRandomBytes(32), then a local AES-GCM seal) and
  # sends only that key to kms:Encrypt -- the DEK never leaves the process for
  # KMS to mint, so the API that mints one is never called. Nothing re-wraps
  # ciphertext under a different key either, so kms:ReEncrypt* has no caller.
  # Both were in the Vault-era convention this grant was copied from, and both
  # are removed here. OpenBao's own awskms seal page says the same:
  # "OpenBao needs the following permissions on the KMS key: kms:Encrypt,
  # kms:Decrypt, kms:DescribeKey."
  #
  # Nothing on the STANDBY path asks for more than the AWS node does. It runs
  # the same OpenBao 2.6.2 with the same `seal "awskms"` stanza (region +
  # kms_key_id and nothing else); the only difference is where the credentials
  # come from -- web identity here, an instance profile there -- and that is an
  # STS concern, not a KMS one. Restoring a snapshot is Decrypt: the barrier
  # keyring inside it was wrapped by this same key. The snapshot bytes come
  # from GCS, not S3, so no bucket-key Decrypt belongs here.
  #
  # Steady state adds no action either: the seal health check runs one
  # Encrypt->Decrypt round trip every ten minutes, both already granted.
  statement {
    sid    = "SealKeyByAlias"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    # Every region: the standby names the replica region's copy.
    #
    # By alias-plus-condition rather than by exact ARN, unlike the drill role:
    # this stack does not create the key, so it has no ARN to reference at
    # grant time and has to resolve it by the alias the lineage attaches.
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

    # `sub` ONLY, deliberately -- no `oaud` condition here, unlike the standby
    # seal role above.
    #
    # This role used to pin `oaud` to the subject id as well, on the assumption
    # that a Google token's audience mirrors its subject. It does not, and the
    # job could not be created at all:
    #
    #   Error 403: Failed to obtain the location of the source S3 bucket.
    #   AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
    #
    # Google's own documented trust policy for agentless S3 transfers conditions
    # on `accounts.google.com:sub` and nothing else -- the audience of the token
    # its Storage Transfer service agent mints is not documented, and pinning a
    # guess at it fails closed.
    #
    # The standby seal role above is a different case and keeps its `oaud`: that
    # token is a GCE instance identity token, minted by our own systemd timer
    # with `audience=sts.amazonaws.com` explicitly, so the value is ours to
    # assert. Here the token is minted by a Google-managed service agent.
    #
    # `sub` is the constraint that matters either way: it pins this project's
    # Storage Transfer service agent exactly, and that agent is Google-managed
    # and project-scoped, so no other principal can present it.
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
