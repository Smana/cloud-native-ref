region                       = "eu-west-3"
openbao_root_token_secret_id = "openbao/cloud-native-ref/tokens/root"
domain_name                  = "priv.aws.ogenki.io"
intermediate_ca_secret_name  = "certificates/priv.aws.ogenki.io/intermediate-ca" # pragma: allowlist secret
pki_country                  = "France"
pki_organization             = "Ogenki"
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

# Human login through ZITADEL OIDC (ADR-0034).
#
# Safe to leave set even before ZITADEL exists. oidc.tf lists the secret before
# reading it, so a missing secret means "not bootstrapped yet" (no OIDC method,
# clean converge) rather than a plan error. That is what lets this stay
# committed -- and it has to stay committed, because when it was commented out
# every rebuild applied with OIDC disabled and DESTROYED the auth mount, the
# role and the identity group that the previous cluster had.
#
# The ordering knot itself has not gone away:
#
#   this stack  ->  ZITADEL's secrets come from here
#   ZITADEL     ->  must be running before a client can be registered in it
#   the client  ->  is what this value points at
#
# So a brand-new platform still needs the client registered once, after the
# platform converges. The store key IS the AWS secret name (see
# scripts/lib/cloud-secret-store.sh -- `harbor-oidc` and `security-flux-ui-oidc`
# are literal secret names, not prefixed keys):
#
#   ./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws \
#     --region eu-west-3 --apply
#
# The next apply then picks the secret up on its own -- no edit here.
#
# Granting a human the role the external group binds to remains a separate step,
# because a human does not exist in ZITADEL until their first login:
#
#   ./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws \
#     --region eu-west-3 --grant-admin <your-email> --apply
openbao_oidc_secret_id = "openbao-oidc"
