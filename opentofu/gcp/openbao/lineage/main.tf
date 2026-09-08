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
  # checkov:skip=CKV_GCP_62:Same answer as CKV_AWS_18 on the S3 side. Access logging needs a second bucket with its own lifecycle and cost, to record reads of objects that are useless without the AWS seal key -- every object here is a mirror of an already-envelope-encrypted S3 object. Cloud Audit Logs cover the IAM and KMS calls that decide whether a read can succeed.
  name                        = local.snapshot_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  # Belt and braces on top of uniform access: uniform access removes per-object
  # ACLs, but an IAM binding to allUsers would still make this public. Enforced
  # prevention refuses that binding outright, which is the right answer for a
  # bucket whose objects are OpenBao's storage.
  public_access_prevention = "enforced"
  force_destroy            = false

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

# The standby node reads the same objects, and this grant is the one that is
# easy to leave out: the CI drill above exercises the bucket constantly, so the
# mirror looks reachable, while the identity that matters during an actual AWS
# outage has never touched it.
#
# It had in fact been left out. Measured 2026-09-05 -- a GCE instance running as
# openbao-node, asked to rehydrate from the mirror, got as far as listing:
#
#   STANDBY no-static-credential OK
#   STANDBY identity-token-file bytes=656
#   STANDBY gcs-list FAILED
#
# The AWS half of the failover was already proven by then (the node assumes
# openbao-standby-seal over web identity and the awskms seal unwraps the barrier
# key), which is exactly what made this the remaining gap: the standby could
# unseal a snapshot it had no permission to fetch.
#
# objectViewer, not objectUser: the standby restores FROM the mirror and must
# never write to it. The AWS bucket stays the store of record, and Storage
# Transfer is the only writer here (see transfer.tf).
resource "google_storage_bucket_iam_member" "node_reader" {
  bucket = google_storage_bucket.snapshot.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.openbao_node.email}"
}
