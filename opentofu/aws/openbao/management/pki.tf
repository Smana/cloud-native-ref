resource "vault_mount" "pki" {
  path        = var.pki_mount_path
  type        = "pki"
  description = var.pki_common_name

  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# The openssl-made intermediate IS the issuer -- the shape GCP has had since
# 2026-08-24, adopted here.
#
# This stack used to import a bundle containing the ROOT key and have OpenBao
# generate and sign its own intermediate inside the mount (four resources:
# key, CSR, root_sign_intermediate, set_signed). That put the root private key
# on a networked system, which the PKI & Secrets page carried as an accepted
# trade-off for a reference platform. It is no longer traded: the root signed
# this intermediate offline, once, and the `root-ca` secret that held its key
# has been deleted from Secrets Manager. Tailnet clients now trust ONE root for
# both clouds.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.intermediate_ca.secret_string)["bundle"]
}
