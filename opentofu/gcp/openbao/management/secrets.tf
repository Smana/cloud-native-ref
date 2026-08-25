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
