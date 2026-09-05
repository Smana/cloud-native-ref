# Storage Transfer Service pulls the AWS lineage's bucket into this one.
#
# Why STS rather than a second upload from the snapshot CronJob: the CronJob
# runs in aws-0, whose OIDC issuer changes on every rebuild, so a GCP Workload
# Identity Pool trusting it would need re-federating after each eks/init. The
# transfer service agent's identity is deterministic per project, so the AWS
# side can trust it once (opentofu/shared/aws-gcp-federation, role
# `openbao-snapshot-mirror`) and the trust never follows a rebuilt cluster.
#
# Federated identity: STS presents a Google-issued token for its service agent
# to AWS STS and assumes var.aws_mirror_role_arn. No key at rest on either side.
# The API this whole file depends on, enabled here rather than left as a
# hand-run prerequisite.
#
# Without it `google_storage_transfer_job` fails at creation with a message that
# names neither the API nor the project setting:
#
#   Error 403: Failed to obtain the location of the source S3 bucket.
#   AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity
#
# That reads as an IAM trust-policy problem and sends you to the AWS side, which
# is where 2026-09-05 was spent before `googleServiceAccounts.get` returned the
# real reason: "Storage Transfer API has not been used in project ... or it is
# disabled". The subject id and the trust policy were correct throughout.
#
# `disable_on_destroy = false` because destroying this stack must not turn the
# API off for the whole project -- the lineage stack is deliberately long-lived,
# but a targeted destroy of it should not reach that far.
resource "google_project_service" "storagetransfer" {
  project            = var.project_id
  service            = "storagetransfer.googleapis.com"
  disable_on_destroy = false
}

# depends_on, because a data source is otherwise free to read before the API is
# enabled. It answered with the correct subject id even while the API was
# disabled, so the failure surfaced later and somewhere else.
data "google_storage_transfer_project_service_account" "default" {
  project    = var.project_id
  depends_on = [google_project_service.storagetransfer]
}

# The service agent writes into the sink bucket.
resource "google_storage_bucket_iam_member" "transfer_sink" {
  bucket = google_storage_bucket.snapshot.name
  role   = "roles/storage.legacyBucketWriter"
  member = "serviceAccount:${data.google_storage_transfer_project_service_account.default.email}"
}

resource "google_storage_transfer_job" "s3_mirror" {
  count = var.aws_mirror_role_arn == "" ? 0 : 1

  description = "Mirror OpenBao raft snapshots from the AWS lineage bucket"
  project     = var.project_id

  transfer_spec {
    # NO `path` on either side, and that is load-bearing rather than incidental.
    # Storage Transfer preserves an object's name only when neither source nor
    # sink carries a path prefix, and the snapshot's name is now the only record
    # of which seal encrypted it -- `<timestamp>-<seal>.snap`. A mirrored object
    # that arrived as `awskms/<timestamp>-awskms.snap` would drop out of the
    # selector's candidate set entirely (it lists non-recursively and strips
    # through the last "/"), so the sink would look like it held no AWS
    # snapshots at all. Adding a prefix here breaks the cross-cloud restore
    # silently, in the direction that only shows up during a failover.
    aws_s3_data_source {
      bucket_name = var.aws_snapshot_bucket_name
      role_arn    = var.aws_mirror_role_arn
    }

    gcs_data_sink {
      bucket_name = google_storage_bucket.snapshot.name
    }

    transfer_options {
      # Snapshots are immutable objects with unique names; never overwrite and
      # never delete on the sink -- the sink also holds GCP-taken snapshots.
      overwrite_objects_already_existing_in_sink = false
      delete_objects_unique_in_sink              = false
      delete_objects_from_source_after_transfer  = false
    }
  }

  schedule {
    schedule_start_date {
      year  = 2026
      month = 9
      day   = 1
    }
    start_time_of_day {
      hours   = var.mirror_start_hour_utc
      minutes = 0
      seconds = 0
      nanos   = 0
    }
    # Daily. Tighten to "3600s" for the production posture (hourly snapshots).
    repeat_interval = "86400s"
  }

  depends_on = [google_storage_bucket_iam_member.transfer_sink, google_project_service.storagetransfer]
}
