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
#   GCP-0078 (no versioning): every object name is a unique snapshot
#   timestamp and the mirror job never overwrites
#   (transfer_options.overwrite_objects_already_existing_in_sink = false in
#   transfer.tf), so there is no in-place write for a version history to
#   protect against.
#trivy:ignore:GCP-0066
#trivy:ignore:GCP-0078
resource "google_storage_bucket" "snapshot" {
  name                        = local.snapshot_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  # Snapshots are small; keep the history the AWS bucket keeps.
  lifecycle_rule {
    condition {
      age = 120
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
