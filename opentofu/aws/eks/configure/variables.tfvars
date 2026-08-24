cluster_name = "mycluster-0"
region       = "eu-west-3"
env          = "dev"

private_domain_name = "priv.aws.ogenki.io"
public_domain_name  = "cloud.ogenki.io"

# Cluster-internal bootstrap resources (gateway CRDs, flux-system namespace +
# secrets + vars ConfigMap, storage classes) are created in this stage, after
# the cluster exists — see kubernetes.tf. They previously lived in eks/init but
# that forced the kubectl provider to configure from not-yet-created cluster
# outputs (alekc/kubectl can't defer → "no configuration has been provided").
cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
# github_app_secret_name defaults to github/flux-app
# gateway_api_version defaults to v1.6.1 (must match flux/sources/gitrepo-gateway-api.yaml ref)

# Flux sync configuration
flux_sync_url = "https://github.com/Smana/cloud-native-ref.git"
# flux_git_ref defaults to refs/heads/main (can be overridden via TF_VAR_flux_git_ref)
