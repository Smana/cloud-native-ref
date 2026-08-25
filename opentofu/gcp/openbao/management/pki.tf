resource "vault_mount" "pki" {
  path        = var.pki_mount_path
  type        = "pki"
  description = var.pki_common_name

  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# The openssl-made intermediate IS the issuer. This is the whole difference from
# the AWS stack, and it deletes four resources.
#
# AWS imports a bundle containing the ROOT key, then has OpenBao generate its own
# intermediate and sign it internally:
#   vault_pki_secret_backend_key
#     -> vault_pki_secret_backend_intermediate_cert_request
#     -> vault_pki_secret_backend_root_sign_intermediate
#     -> vault_pki_secret_backend_intermediate_set_signed
# That sequence exists only to produce an intermediate UNDER an imported root.
# Here the root never enters OpenBao at all -- it signed this intermediate
# offline, once -- so importing the intermediate directly is both sufficient and
# the point.
#
# Verified on a live server 2026-08-25 before this file was written, because the
# design rested on it: importing the bundle produced an issuer AND a key, a role
# issued a leaf, and the leaf verified to the offline root. See
# docs/superpowers/specs/2026-08-25-gcp-openbao-verification.md.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.google_secret_manager_secret_version.intermediate_ca.secret_data)["bundle"]
}
