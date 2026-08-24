env  = "dev"
name = "mycluster-0" # Generated with petname

tags = {
  GithubRepo = "cloud-native-ref"
  GithubOrg  = "Smana"
}

enable_ssm = true

identity_providers = {
  zitadel = {
    client_id      = "293655038025345449"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
