# The snapshot bucket and its key, adopted from the Crossplane MRs that used to
# live in security/aws-0/openbao-snapshot/. Both are imported (Task 15), not
# recreated: the bucket already holds snapshots.
#
# Why they move: rehydrate reads this bucket BEFORE the cluster exists, and the
# GCS mirror (opentofu/gcp/openbao/lineage) pulls from it whether or not gcp-0
# has ever been built. A bucket created by a cluster cannot be a precondition
# of that cluster.

data "aws_caller_identity" "this" {}

locals {
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.region) : var.snapshot_bucket_name
}

resource "aws_kms_key" "snapshot" {
  # checkov:skip=CKV2_AWS_64:Default key policy, for the same reason as the seal key in kms.tf -- account root plus IAM grants, rather than an explicit policy whose blast radius on a mistake is an unreadable snapshot bucket. This key wraps the objects; the seal key wraps their contents, so neither alone is enough to read a snapshot.
  description             = "Used for the Vault s3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "snapshot" {
  name          = var.snapshot_key_alias
  target_key_id = aws_kms_key.snapshot.key_id
}

# AWS-0089 is trivy's name for the same finding as CKV_AWS_18 below, and the
# answer is the same one -- suppressed in both scanners so they do not disagree
# about a decision that has been made.
#trivy:ignore:AWS-0089
resource "aws_s3_bucket" "snapshot" {
  # Three Checkov rules are answered by the design rather than by a setting, so
  # they are skipped here with the answer rather than left as standing alerts.
  #
  # checkov:skip=CKV_AWS_144:Cross-region replication is answered CROSS-CLOUD instead. transfer.tf mirrors this bucket into GCS daily, which is what the fallback in ADR-0033 restores from -- a second AWS region would not survive the failure this design is for.
  # checkov:skip=CKV2_AWS_62:Nothing consumes S3 events here. The snapshot job reports its own outcome and the drill asserts freshness by listing; a notification target would be a component with no reader.
  # checkov:skip=CKV_AWS_18:Access logging would need a second bucket with its own lifecycle and cost, to record reads of objects that are already useless without the seal key -- every object is envelope-encrypted by alias/openbao-seal, and the key is granted to three principals. The API-level audit trail is CloudTrail, which covers the KMS calls that actually matter.
  bucket = local.snapshot_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_public_access_block" "snapshot" {
  bucket                  = aws_s3_bucket.snapshot.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.snapshot.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# Versioning is new (the Crossplane bucket had none). It is what lets a
# snapshot overwritten by a bad run be recovered, and the lifecycle rule below
# keeps noncurrent versions from accumulating.
resource "aws_s3_bucket_versioning" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Same rules the Crossplane BucketLifecycleConfiguration applied: Glacier after
# 30 days, gone after 120.
resource "aws_s3_bucket_lifecycle_configuration" "snapshot" {
  bucket = aws_s3_bucket.snapshot.id

  rule {
    id     = "glacier"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }
  }

  # A snapshot upload that dies partway leaves its parts billable and invisible:
  # they do not appear in a listing, they are not covered by the expiration rule
  # below (which matches objects, and an incomplete upload is not one yet), and
  # nothing in this stack would ever notice. The snapshot job runs daily and the
  # node it runs on is destroyed nightly, so a failed upload is an ordinary
  # event here rather than a rare one.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expiration"
    status = "Enabled"
    filter {}

    expiration {
      days = 120
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.snapshot]
}
