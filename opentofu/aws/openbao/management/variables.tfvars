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
