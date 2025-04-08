env          = "dev"
cluster_name = "mycluster-0" # Generated with petname

flux_sync_repository_url = "https://github.com/Smana/cloud-native-ref.git"

tags = {
  GithubRepo = "cloud-native-ref"
  GithubOrg  = "Smana"
}

enable_ssm = true

karpenter_limits = {
  "default" = {
    cpu    = "20"
    memory = "64Gi"
  }
  "io" = {
    cpu    = "20"
    memory = "64Gi"
  }
}

cluster_identity_providers = {
  zitadel = {
    client_id      = "293655038025345449"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
