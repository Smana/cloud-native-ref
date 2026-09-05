resource "vault_pki_secret_backend_role" "this" {
  backend          = vault_mount.pki.path
  name             = lower(var.pki_organization)
  allowed_domains  = var.pki_domains
  allow_subdomains = true
  organization     = [var.pki_organization]
  country          = [var.pki_country]
  key_usage = [
    "DigitalSignature",
    "KeyAgreement",
    "KeyEncipherment",
  ]
  # Leaf lifetime, not mount lifetime. These used to be pki_max_lease_ttl -
  # three years - which meant cert-manager, renewing at two-thirds of
  # lifetime, would not rotate anything for two years. Automated issuance is
  # the whole reason to run a PKI engine; short leaves are the payoff.
  # var.pki_max_lease_ttl still bounds the mount and the leases issued from it.
  ttl     = var.pki_leaf_ttl
  max_ttl = var.pki_leaf_max_ttl
}
