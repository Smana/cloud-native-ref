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

#trivy:ignore:AVD-AWS-0104
resource "aws_kms_key" "snapshot" {
  description             = "Used for the Vault s3 bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "snapshot" {
  name          = var.snapshot_key_alias
  target_key_id = aws_kms_key.snapshot.key_id
}

resource "aws_s3_bucket" "snapshot" {
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
