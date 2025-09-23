env  = "dev"
name = "mycluster-0" # Generated with petname

flux_sync_repository_url = "https://github.com/Smana/cloud-native-ref.git"

tags = {
  GithubRepo = "cloud-native-ref"
  GithubOrg  = "Smana"
}

enable_ssm = true

cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"

karpenter_limits = {
  "default" = {
    cpu    = "21"
    memory = "64Gi"
  }
  "io" = {
    cpu    = "20"
    memory = "64Gi"
  }
}

identity_providers = {
  zitadel = {
    client_id      = "293655038025345449"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
