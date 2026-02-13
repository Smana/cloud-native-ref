env                 = "dev"
name                = "mycluster-0" # Generated with petname
private_domain_name = "priv.cloud.ogenki.io"
public_domain_name  = "cloud.ogenki.io"

tags = {
  GithubRepo = "cloud-native-ref"
  GithubOrg  = "Smana"
}

enable_ssm = true

cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"

identity_providers = {
  zitadel = {
    client_id      = "293655038025345449"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
