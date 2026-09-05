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
# trade-off for a reference platform.
#
# WRITTEN FOR THE OFFLINE SHAPE, WHICH HAS NOT HAPPENED YET on AWS. This code
# reads a pre-signed intermediate from `certificates/priv.aws.ogenki.io/
# intermediate-ca`, a secret the offline ceremony creates -- Task 14 of the
# Stage 1 plan, still unrun. Until it does:
#
#   * this stack cannot apply, because that secret does not exist;
#   * `certificates/priv.aws.ogenki.io/root-ca`, which holds the root PRIVATE
#     KEY, is still in Secrets Manager, and the live mount's issuer is still
#     the one OpenBao generated and signed for itself;
#   * so the root key IS on a networked system today. Task 17 Step 2 deletes
#     that secret, deliberately only after the new chain has issued a
#     certificate.
#
# An earlier version of this comment said the deletion had already happened.
# It had not, and stating a security improvement in the past tense before it is
# made is the worst direction for the error -- it retires the warning while the
# exposure is still there. The PKI & Secrets page carries the same gating in a
# warning callout; the two are meant to agree.
#
# After the ceremony: the root signs each cloud's intermediate offline, only the
# intermediate's cert+key bundle reaches a networked store, and tailnet clients
# trust ONE root for both clouds.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.intermediate_ca.secret_string)["bundle"]
}
