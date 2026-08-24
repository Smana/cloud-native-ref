resource "google_service_account" "openbao" {
  account_id   = "openbao-${var.env}"
  display_name = "OpenBao node"
  project      = var.project_id
}

# Unseal only. Not admin on the key. Bound to the data source in kms.tf, not a
# managed resource -- the key ring and key are a bootstrap prerequisite (see
# kms.tf for why).
resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  crypto_key_id = data.google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.openbao.email}"
}

# Read the server certificate at boot. Scoped to that ONE secret -- not
# project-wide secretAccessor, which would let the node read Flux's GitHub App
# credentials and every other secret in the project.
#
# var.server_cert_secret_name names a secret created by a different task (the
# PKI/certificate task). It does not exist yet at scaffolding time -- this
# stack only runs `tofu validate`, never `tofu apply`, so nothing here resolves
# the reference against the cloud.
resource "google_secret_manager_secret_iam_member" "openbao_server_cert" {
  project   = var.project_id
  secret_id = var.server_cert_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openbao.email}"
}
