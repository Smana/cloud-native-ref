# Unseal with the GCP key, in gcpckms mode. In awskms mode (a standby restoring
# an AWS snapshot) these grants are unused and harmless -- the seal then talks
# to AWS KMS through the federated role in var.aws_seal_role_arn. The service
# account itself is the lineage's (lineage.tf): its unique ID is what the AWS
# side trusts, so it must not be recreated with this stack.
resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  crypto_key_id = data.google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${local.lineage.openbao_node_sa_email}"
}

resource "google_kms_crypto_key_iam_member" "openbao_key_get" {
  crypto_key_id = data.google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.viewer"
  member        = "serviceAccount:${local.lineage.openbao_node_sa_email}"
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
  member    = "serviceAccount:${local.lineage.openbao_node_sa_email}"
}
