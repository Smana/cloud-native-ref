# The role cert-manager issues through. Scoped to this cloud's private domain,
# plus whatever `pki_additional_allowed_domains` adds -- nothing, by default.
# ADR-0017's per-cloud domains stand: each name resolves to one CA.
resource "vault_pki_secret_backend_role" "cert_manager" {
  backend = vault_mount.pki.path
  name    = lower(var.pki_organization)
  # Narrow by default, widened only by deliberate input.
  #
  # Both clouds' intermediates were signed by the same offline root, so a
  # chain-valid certificate from either CA is trusted by everything that trusts
  # the root. Listing "priv.aws.ogenki.io" here unconditionally would therefore
  # let a GCP-only deploy mint a trusted cert for ANY AWS private name --
  # bao.priv.aws.ogenki.io included. That reach is worth having on a standby and
  # is pure blast radius on a GCP-only lineage, so it is an input rather than a
  # constant.
  #
  # It is explicit rather than left to the snapshot precisely because this stack
  # MANAGES this role: after a rehydrate restores the widened role from an AWS
  # snapshot, the very next `tofu apply` here would reconcile it back to
  # whatever this list says. "The snapshot brings it back" is not a mechanism
  # that survives the next apply -- see the variable's own comment.
  allowed_domains  = concat([var.private_domain_name], var.pki_additional_allowed_domains)
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
