# One policy. The AWS stack also carries admin, snapshot, pki-admin and app
# policies; none has a consumer on GCP, and the design scopes this stack to PKI
# only. Add them when something needs them, not before.
resource "vault_policy" "cert_manager" {
  name   = "cert-manager"
  policy = file("policies/cert-manager.hcl")
}
