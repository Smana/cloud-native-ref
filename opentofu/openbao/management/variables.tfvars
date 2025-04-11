region                           = "eu-west-3"
openbao_root_token_secret_id     = "openbao/cloud-native-ref/tokens/root"
domain_name                      = "priv.cloud.ogenki.io"
root_ca_secret_name              = "certificates/priv.cloud.ogenki.io/root-ca"
openbao_certificates_secret_name = "certificates/priv.cloud.ogenki.io/openbao"
cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
pki_country                      = "France"
pki_organization                 = "Ogenki"
pki_domains = [
  "cluster.local",
  "priv.cloud.ogenki.io"
]
tags = {
  project = "cloud-native-ref"
  owner   = "Smana"
}
