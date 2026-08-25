env = "dev"
# <cloud>-<ordinal>. Symmetric with GCP's gcp-0 so neither cloud is the
# unlabelled default -- the same rule ADR-0017 applies to DNS names. Was
# "mycluster-0" (petname-generated); renamed 2026-08-25 while both clusters were
# destroyed, since an EKS cluster name is immutable.
name = "aws-0"

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
