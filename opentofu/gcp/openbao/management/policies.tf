# One policy. The AWS stack also carries admin, snapshot, pki-admin and app
# policies; none has a consumer on GCP, and the design scopes this stack to PKI
# only. Add them when something needs them, not before.
#
# `templatefile` rather than `file` so the granted path is derived from the mount
# and role that actually exist, instead of being restated as a literal that
# nothing checks. See policies/cert-manager.hcl.tftpl.
resource "vault_policy" "cert_manager" {
  name = "cert-manager"

  policy = templatefile("${path.module}/policies/cert-manager.hcl.tftpl", {
    mount = vault_mount.pki.path
    role  = vault_pki_secret_backend_role.cert_manager.name
  })
}
