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
# THE OFFLINE SHAPE, AND IT IS THE LIVE ONE. This code reads a pre-signed
# intermediate from `certificates/priv.aws.ogenki.io/intermediate-ca` and
# generates nothing inside OpenBao, so the mount's issuer is the intermediate the
# offline ceremony signed. Verified 2026-09-08 against the live account:
#
#   * `certificates/priv.aws.ogenki.io/intermediate-ca` exists and this stack
#     applies from it;
#   * `certificates/priv.aws.ogenki.io/root-ca`, which used to hold the root
#     PRIVATE KEY, is deleted -- no cloud store holds it;
#   * a node rehydrated from the newest snapshot serves an issuer that
#     `openssl verify -CAfile .github/openbao-root-ca.pem` accepts, and the
#     weekly restore drill asserts exactly that on every run.
#
# An earlier version of this comment said the deletion had already happened
# before it had, and the version after it went on saying the opposite once it
# had. Both directions mislead: one retires a warning over a live exposure, the
# other leaves a warning standing over a closed one, and a reader cannot tell
# which they are looking at. Hence the date and the re-check above -- the claim
# is falsifiable rather than asserted. The PKI & Secrets page carries the same
# statement; the two are meant to agree.
#
# After the ceremony: the root signs each cloud's intermediate offline, only the
# intermediate's cert+key bundle reaches a networked store, and tailnet clients
# trust ONE root for both clouds.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.intermediate_ca.secret_string)["bundle"]
}
