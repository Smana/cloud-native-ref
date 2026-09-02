locals {
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.project_id) : var.snapshot_bucket_name
}

# The snapshot bucket, adopted from the Crossplane MR that used to live in
# security/gcp-0/openbao-snapshot/gcs-bucket.yaml (imported in Task 15). It
# moves for the same reason the AWS one does -- rehydrate reads it before the
# cluster exists -- plus one more: it is the MIRROR target for AWS snapshots,
# and the DR promise cannot depend on gcp-0 having been built once.
#
# Two findings accepted as-is, same call the Crossplane-era bucket already
# made:
#   GCP-0066 (no customer-managed key): Google-managed encryption is enough
#   for ~1 KB backup objects; there is no key-rotation policy this bucket
#   needs to participate in.
#
# GCP-0078 (no versioning) is NOT suppressed, and the reasoning that would have
# suppressed it was wrong. It ran: every object name is a unique timestamp and
# the mirror never overwrites, so there is nothing for a version history to
# protect. Both halves are true and the conclusion still does not follow -- the
# failback step in the cross-cloud runbook has a human typing an object name at
# a `gcloud storage cp`, which is precisely an in-place overwrite of a snapshot
# that may be the only good one. The AWS sibling reached the opposite call for
# the identical bucket shape (opentofu/aws/openbao/lineage/s3.tf: "what lets a
# snapshot overwritten by a bad run be recovered"), and two lineage buckets
# disagreeing about the same risk is worse than either answer. Versioning is on,
# with noncurrent versions expiring so history cannot accumulate.
#trivy:ignore:GCP-0066
resource "google_storage_bucket" "snapshot" {
  name                        = local.snapshot_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  # Snapshots are small; keep the history the AWS bucket keeps.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 120
    }
    action {
      type = "Delete"
    }
  }

  # Bounds what versioning can cost. Without it an overwritten object's previous
  # generations live forever, because the age rule above matches on the object's
  # own age rather than on how long a generation has been superseded.
  lifecycle_rule {
    condition {
      num_newer_versions         = 1
      days_since_noncurrent_time = 30
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    app = "openbao"
  }
}

# The OpenBao node's identity. Created HERE, not in the cluster stack, so its
# unique ID is stable: the AWS role `openbao-standby-seal` trusts that ID, and a
# service account recreated with the cluster would get a new one and silently
# break the trust. The cluster stack reads it through remote state.
resource "google_service_account" "openbao_node" {
  account_id   = "openbao-node"
  display_name = "OpenBao node (lineage identity; trusted by the AWS seal role)"
  project      = var.project_id
}

# The CI drill's identity, impersonated from GitHub Actions through the WIF pool
# in github-wif.tf. Reads the bucket, nothing else.
resource "google_service_account" "openbao_drill" {
  account_id   = "openbao-drill"
  display_name = "OpenBao restore drill (GitHub Actions)"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "drill_reader" {
  bucket = google_storage_bucket.snapshot.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.openbao_drill.email}"
}
