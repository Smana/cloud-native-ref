# The role cert-manager issues through. Scoped to this cloud's private domain
# AND, now, the AWS one: a lineage's OpenBao can be running on either cloud
# after a failover, and the roles it issues through come back exactly as the
# snapshot recorded them. ADR-0017's per-cloud domains still stand -- each name
# resolves to one CA -- this just lets either cloud's OpenBao issue for both.
resource "vault_pki_secret_backend_role" "cert_manager" {
  backend = vault_mount.pki.path
  name    = lower(var.pki_organization)
  # Both private domains, like AWS: when this OpenBao is the restored STANDBY of
  # the AWS lineage it issues for aws-0 too. (Irrelevant on a rehydrated node --
  # the role comes back inside the snapshot -- but a fresh GCP-only lineage must
  # start with the same shape.)
  allowed_domains  = [var.private_domain_name, "priv.aws.ogenki.io"]
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
