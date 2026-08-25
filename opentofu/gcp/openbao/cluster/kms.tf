# Auto-unseal key. Looked up by name, NOT managed here.
#
# NOT because `tofu destroy` would fail on them -- it wouldn't. The google
# provider's delete for both `google_kms_key_ring` and `google_kms_crypto_key`
# is a NO-OP: it removes the object from OpenTofu state and returns success
# without calling any GCP delete API (there mostly isn't one -- key rings
# cannot be deleted at all, and a crypto key's "deletion" only schedules its
# versions for destruction). A destroy of a stack that managed them directly
# would exit 0 just like this one does.
#
# The real reasons they are out-of-band data sources instead:
#
#   - CREATE breaks on rebuild. The no-op delete above means the key ring
#     still exists server-side after a "successful" destroy. The NEXT
#     `tofu apply`'s `google_kms_key_ring` resource block would try to CREATE
#     it again and fail with ALREADY_EXISTS -- a managed resource has no
#     "adopt if present" mode.
#   - DESTROY is a silent trap, not a loud one. If `google_kms_crypto_key`
#     WERE managed here, `tofu destroy` would call the provider's delete,
#     which schedules that key's VERSIONS for destruction -- and because the
#     call still returns success (see above), the run exits 0 while quietly
#     scheduling destruction of the unseal key every sealed OpenBao instance
#     depends on. Nothing in the exit code or the destroy script's tolerance
#     policy (workflows.tm.hcl) would flag it.
#
# Re-testing "does `tofu destroy` fail on these" and finding that it doesn't
# is not evidence the bootstrap step is unnecessary -- it is exactly the
# no-op behavior this comment describes. The failure these two points guard
# against shows up on the NEXT apply (ALREADY_EXISTS) or silently in Cloud KMS
# version state (scheduled destruction), not in this stack's own exit code.
#
# So the key ring and key are created ONCE, out of band, as a bootstrap
# prerequisite -- exactly like the S3 state bucket (see backend.tf) -- and
# this stack only reads them:
#
#   # The API is NOT enabled by default on a fresh project. Without this the
#   # keyring create fails with PERMISSION_DENIED and an interactive prompt that
#   # defaults to "no" -- measured 2026-08-25 on ogenki-435905.
#   gcloud services enable cloudkms.googleapis.com --project ogenki-435905
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
