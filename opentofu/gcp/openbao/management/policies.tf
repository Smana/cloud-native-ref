# Two policies now. The AWS stack also carries admin, pki-admin and app
# policies; none of those has a consumer on GCP, and the design scopes this
# stack to PKI only. Add them when something needs them, not before.
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

# Creating raft snapshots. Grants on sys/storage/raft/*, a restricted endpoint
# callable only from the root namespace -- see auth.tf. Plain file() rather
# than templatefile like cert_manager above: the granted path is a literal,
# cloud-neutral raft endpoint with no mount or role to derive it from.
resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = file("${path.module}/policies/snapshot.hcl")
}
