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
# The EKS API server validates OIDC tokens against ONE value, compared against
# the token's `aud` claim. This is a ZITADEL PROJECT id, not an application's
# client id, and that distinction is the whole point.
#
# ZITADEL puts every application of a project into `aud`, plus the project id
# itself. Verified on 2026-08-29 by reading an issued token's audience straight
# out of the eventstore (the `oidc_session.added` payload):
#
#   audience: [headlamp, flux-ui, headlamp-proxy, harbor, grafana,
#              388445486190712688]   <- the project id
#
# Pinning the project id therefore accepts a token from ANY client in the
# `platform` project, so a new consumer needs no change here. Pinning a single
# application's client id -- which this was until 2026-08-29
# (293655038025345449, the `eks-mycluster-0-kubectl` app, and in the legacy
# `Ogenki` project at that) -- accepts that one app and silently rejects every
# other. Headlamp authenticated fine and then got 401s from the API server with
# nothing logged anywhere; it took an evening to find.
#
# Changing this is not a plan-and-apply: an EKS identity provider config is
# immutable, so it must be disassociated and re-associated (~20 min, with OIDC
# auth to the API server down in between). IAM authentication is unaffected,
# which is what `aws eks get-token` kubeconfigs use.
identity_providers = {
  zitadel = {
    client_id      = "388445486190712688"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
