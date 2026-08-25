# The role cert-manager issues through. Scoped to this cloud's private domain
# only: the GCP PKI issues for *.priv.gcp.ogenki.io and nothing else, while the
# AWS one keeps *.priv.aws.ogenki.io. ADR-0017's per-cloud domains make that
# split clean -- there is no name a client could resolve to either CA.
resource "vault_pki_secret_backend_role" "cert_manager" {
  backend          = vault_mount.pki.path
  name             = lower(var.pki_organization)
  allowed_domains  = [var.private_domain_name]
  allow_subdomains = true
  organization     = [var.pki_organization]
  country          = [var.pki_country]

  key_usage = [
    "DigitalSignature",
    "KeyAgreement",
    "KeyEncipherment",
  ]

  # Leaf lifetime, not mount lifetime. The AWS stack learned this the hard way:
  # setting these to the mount's max (years) means cert-manager, which renews at
  # two-thirds of lifetime, would not rotate anything for a very long time.
  # Automated issuance is only worth having if it actually exercises renewal.
  ttl     = var.pki_leaf_ttl
  max_ttl = var.pki_leaf_max_ttl

  depends_on = [vault_pki_secret_backend_config_ca.pki]
}
