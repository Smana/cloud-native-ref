region                           = "eu-west-3"
openbao_root_token_secret_id     = "openbao/cloud-native-ref/tokens/root"
domain_name                      = "priv.aws.ogenki.io"
intermediate_ca_secret_name      = "certificates/priv.aws.ogenki.io/intermediate-ca" # pragma: allowlist secret
openbao_certificates_secret_name = "certificates/priv.aws.ogenki.io/openbao"
pki_country                      = "France"
pki_organization                 = "Ogenki"
# Both private domains: the active OpenBao issues for both clusters (design,
# "PKI"), so a gcp-0 Certificate signed here must be allowed. cluster.local
# covers in-cluster Service names.
pki_domains = [
  "cluster.local",
  "priv.aws.ogenki.io",
  "priv.gcp.ogenki.io"
]
# Include both VPC CIDR and Pod CIDR (secondary CIDR for Cilium ENI prefix delegation)
allowed_cidr_blocks = [
  "10.0.0.0/16",  # VPC CIDR
  "100.64.0.0/16" # Pod CIDR (secondary CIDR)
]
tags = {
  project = "cloud-native-ref"
  owner   = "Smana"
}

# Human login through ZITADEL OIDC (ADR-0034) -- COMMENTED OUT ON PURPOSE, and
# the comment is the instructions, because without them nothing ever sets this
# and oidc.tf stays inert forever.
#
# It cannot be set on a first deploy. There is a genuine ordering knot:
#
#   this stack  ->  ZITADEL's secrets come from here
#   ZITADEL     ->  must be running before a client can be registered in it
#   the client  ->  is what this value points at
#
# So the sequence is, once the platform has converged:
#
#   1. Register the client. The store key IS the AWS secret name (see
#      scripts/lib/cloud-secret-store.sh -- `harbor-oidc` and
#      `security-flux-ui-oidc` are literal secret names, not prefixed keys):
#
#        ./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws \
#          --region eu-west-3 --apply
#
#   2. Uncomment the line below and re-apply THIS stack. oidc.tf is gated on the
#      value being non-empty, so an apply before step 1 is not an error -- it
#      simply creates no OIDC auth method, which is why a first deploy converges
#      cleanly without this.
#
#   3. Grant yourself the role the external group binds to. A human does not
#      exist in ZITADEL until first login, so this cannot happen at bootstrap:
#
#        ./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws \
#          --region eu-west-3 --grant-admin <your-email> --apply
#
# openbao_oidc_secret_id = "openbao-oidc"
