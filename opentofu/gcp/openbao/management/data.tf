# The root token written by `openbao-config.sh init --cloud gcp`.
#
# Shape is {"token": "..."} -- NOT {"root_token": ...}. Reading the wrong key
# and falling back to the whole blob yields
#   configured Vault token contains non-printable characters
# which says nothing about the actual mistake. Measured 2026-08-25.
data "google_secret_manager_secret_version" "openbao_root_token" {
  secret  = var.root_token_secret_name
  project = var.project_id
}

# The openssl-made intermediate: certificate AND private key, as one pem_bundle.
# Created by the offline ceremony (docs/superpowers/specs/2026-08-24-gcp-openbao-design.md),
# never by this stack. The ROOT key is deliberately absent from GCP entirely.
data "google_secret_manager_secret_version" "intermediate_ca" {
  secret  = var.intermediate_ca_secret_name
  project = var.project_id
}
