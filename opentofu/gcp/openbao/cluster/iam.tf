resource "google_service_account" "openbao" {
  account_id   = "openbao-${var.env}"
  display_name = "OpenBao node"
  project      = var.project_id
}

# Unseal. Not admin on the key. Bound to the data source in kms.tf, not a
# managed resource -- the key ring and key are a bootstrap prerequisite (see
# kms.tf for why).
#
# TWO roles are required, and the second is not obvious. The design said
# encrypterDecrypter "and nothing else"; that is wrong, and only a live boot
# showed it:
#
#   Error configuring seal "gcpckms": error checking key existence:
#   PermissionDenied: Permission 'cloudkms.cryptoKeys.get' denied on resource
#   .../cryptoKeys/openbao-unseal (or it may not exist).
#
# OpenBao's gcpckms seal checks the key EXISTS before using it, and
# cryptoKeyEncrypterDecrypter grants encrypt/decrypt without cryptoKeys.get.
# roles/cloudkms.viewer is the least-privileged predefined role that carries it,
# and bound at the crypto-key level it sees only this one key.
#
# The failure is quiet in the worst way: the instance reaches RUNNING and joins
# the MIG while openbao.service crashloops, because the seal is configured
# AFTER the process starts. Measured 2026-08-25.
resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  crypto_key_id = data.google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.openbao.email}"
}

resource "google_kms_crypto_key_iam_member" "openbao_key_get" {
  crypto_key_id = data.google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.viewer"
  member        = "serviceAccount:${google_service_account.openbao.email}"
}

# Read the server certificate at boot. Scoped to that ONE secret -- not
# project-wide secretAccessor, which would let the node read Flux's GitHub App
# credentials and every other secret in the project.
#
# var.server_cert_secret_name names a secret created by a different task (the
# PKI/certificate task, plan Task 3 -- the offline ceremony that loads Secret
# Manager). The real constraint is ordering, not that this stack never
# applies: Task 3's secret must exist in GCP Secret Manager BEFORE this stack
# is applied, or the instance's boot script (startup-script.sh) fails to fetch
# a certificate that isn't there yet. This binding itself only references the
# secret by name/IAM policy, which OpenTofu can create either order -- it is
# the runtime fetch at boot that enforces Task 3 -> this stack.
resource "google_secret_manager_secret_iam_member" "openbao_server_cert" {
  project   = var.project_id
  secret_id = var.server_cert_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openbao.email}"
}
