resource "vault_pki_secret_backend_role" "this" {
  backend          = vault_mount.this.path
  name             = var.pki_organization
  allowed_domains  = var.pki_domains
  allow_subdomains = true
  organization     = [var.pki_organization]
  country          = [var.pki_country]
  key_usage = [
    "DigitalSignature",
    "KeyAgreement",
    "KeyEncipherment",
  ]
  max_ttl = var.pki_max_lease_ttl
  ttl     = var.pki_max_lease_ttl
}
