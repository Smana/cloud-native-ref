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

# The EKS API server validates OIDC tokens against ONE ZITADEL client id, and
# that id is a value ZITADEL generated -- it cannot be chosen, and it is not
# derivable at plan time, because ZITADEL runs *inside* the cluster this stack
# creates. Hence a literal.
#
# `293655038025345449` is the `eks-mycluster-0-kubectl` app (redirect
# http://localhost:8000), used by `kubectl` OIDC login. It lives in the LEGACY
# `Ogenki` ZITADEL project, not the `platform` project that
# scripts/zitadel-oidc-clients.sh manages -- so nothing reconciles it, and
# deleting the Ogenki project would break kubectl auth with an error that names
# neither this file nor the project.
#
# It survives a rebuild only because the cluster is restored from the frozen
# snapshot pinned in security/base/zitadel/sqlinstance.yaml, which still carries
# that project. A ZITADEL bootstrapped EMPTY would mint different ids and this
# value would be stale on arrival.
#
# Changing it is not a plan-and-apply: an EKS identity provider config is
# immutable, so it has to be disassociated and re-associated (~20 min, and
# kubectl OIDC auth is down in between).
#
# Note this is NOT what Headlamp uses. Headlamp authenticates users against its
# own client in the `platform` project and reaches the API server with its own
# ServiceAccount, so it is unaffected by this value.
identity_providers = {
  zitadel = {
    client_id      = "293655038025345449"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
