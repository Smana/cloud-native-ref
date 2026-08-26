resource "vault_approle_auth_backend_role_secret_id" "cert_manager" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.cert_manager.role_name
}

# The credentials External Secrets pulls into the cluster.
#
# The secret ID lands in OpenTofu state, which is why state lives in an
# encrypted S3 bucket. That is the same trade the AWS stack makes; it is worth
# naming rather than leaving implicit, because it is the one piece of this
# design that does put a live credential in state. The PKI's private keys do
# not: the root never enters GCP, and the intermediate is read from Secret
# Manager rather than generated here.
resource "google_secret_manager_secret" "approle_cert_manager" {
  project   = var.project_id
  secret_id = var.approle_secret_name

  replication {
    auto {}
  }
}

# Shape is {role_id, secret_id}, matching what Task 8's ExternalSecret extracts.
resource "google_secret_manager_secret_version" "approle_cert_manager" {
  secret = google_secret_manager_secret.approle_cert_manager.id

  secret_data = jsonencode({
    role_id   = vault_approle_auth_backend_role.cert_manager.role_id
    secret_id = vault_approle_auth_backend_role_secret_id.cert_manager.secret_id
  })
}

# Snapshot agent AppRole
# ----------------------
# Mirrors opentofu/aws/openbao/management/secrets.tf's
# snapshot_approle_credentials. Until workstream 9, this had no GCP consumer at
# all -- see the history note on vault_auth_backend.approle in auth.tf.
locals {
  snapshot_bucket_name = var.snapshot_bucket_name == "" ? format("%s-ogenki-openbao-snapshot", var.region) : var.snapshot_bucket_name
}

resource "google_secret_manager_secret" "snapshot_approle_credentials" {
  project   = var.project_id
  secret_id = var.snapshot_approle_secret_name

  replication {
    auto {}
  }
}

# Root namespace, matching the role -- see auth.tf.
resource "vault_approle_auth_backend_role_secret_id" "snapshot" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.snapshot.role_name
}

resource "google_secret_manager_secret_version" "snapshot_approle_credentials" {
  secret = google_secret_manager_secret.snapshot_approle_credentials.id

  secret_data = jsonencode({
    APPROLE_ROLE_ID   = vault_approle_auth_backend_role.snapshot.role_id
    APPROLE_SECRET_ID = vault_approle_auth_backend_role_secret_id.snapshot.secret_id
    VAULT_ADDR        = local.openbao_address
    BUCKET_NAME       = local.snapshot_bucket_name
    # No RECOVERY_KEYS_SECRET_ID here, unlike AWS. AWS's own comment on that
    # field carries the principle: "a daily backup pod that can read the
    # material for regenerating a root token is a privilege escalation, not a
    # convenience." On GCP the job's identity has no Secret Manager access at
    # all: security/gcp-0/openbao-snapshot/workloadidentity.yaml grants it a
    # GCPWorkloadIdentity scoped to the snapshot bucket and nothing else, so
    # including the key here would advertise an access path that does not
    # exist. GCP's restore therefore stays an operator action, run with
    # credentials granted out of band, not through this stack.
  })
}
