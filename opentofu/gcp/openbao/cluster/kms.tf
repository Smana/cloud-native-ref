# Auto-unseal key. Looked up by name, NOT managed here.
#
# GCP Cloud KMS key rings and crypto keys cannot be deleted at all (a crypto
# key can only have its versions scheduled for destruction; the key and its
# ring live forever). That makes them a bad fit for a stack that is destroyed
# and rebuilt on every test cycle in two ways at once:
#
#   - Teardown can never fully succeed: a `tofu destroy` that tries to delete
#     either object fails, every time.
#   - A rebuild's `tofu apply` fails just as hard, the opposite way: creating
#     a key ring or key that still exists server-side from the previous cycle
#     errors ALREADY_EXISTS.
#
# `lifecycle { prevent_destroy = true }` on a managed resource only papers
# over the first half -- it still leaves the second half, and it still makes
# a strict `destroy` script fail unconditionally (see workflows.tm.hcl), which
# is indistinguishable from a REAL failure to tear down this stack's billable
# compute. So the key ring and key are created ONCE, out of band, as a
# bootstrap prerequisite -- exactly like the S3 state bucket (see backend.tf)
# -- and this stack only reads them:
#
#   gcloud kms keyrings create openbao-dev --location europe-west4 --project ogenki-435905
#   gcloud kms keys create openbao-unseal --location europe-west4 --keyring openbao-dev --purpose encryption --project ogenki-435905
#
# The instance service account gets encrypter/decrypter on the key and nothing
# else (iam.tf) -- it never needs to manage the key, only use it.
data "google_kms_key_ring" "openbao" {
  name     = var.kms_key_ring_name
  project  = var.project_id
  location = var.region
}

data "google_kms_crypto_key" "openbao" {
  name     = var.kms_crypto_key_name
  key_ring = data.google_kms_key_ring.openbao.id
}
