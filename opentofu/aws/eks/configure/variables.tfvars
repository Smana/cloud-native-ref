cluster_name = "aws-0"
region       = "eu-west-3"
env          = "dev"

private_domain_name = "priv.aws.ogenki.io"
public_domain_name  = "cloud.ogenki.io"

# Cluster-internal bootstrap resources (gateway CRDs, flux-system namespace +
# secrets + vars ConfigMap, storage classes) are created in this stage, after
# the cluster exists — see kubernetes.tf. They previously lived in eks/init but
# that forced the kubectl provider to configure from not-yet-created cluster
# outputs (alekc/kubectl can't defer → "no configuration has been provided").
# github_app_secret_name defaults to github/flux-app
# openbao_root_token_secret_id defaults to openbao/cloud-native-ref/tokens/root
# gateway_api_version is NOT set here: it is shared with GCP and passed via
# -var from globals.gateway_api_version in opentofu/config.tm.hcl, the same way
# cilium_version is.

# Flux sync configuration
flux_sync_url = "https://github.com/Smana/cloud-native-ref.git"
# flux_git_ref defaults to refs/heads/main (can be overridden via TF_VAR_flux_git_ref)

# Gemini on Vertex AI for the model gateway: outputs of
# opentofu/shared/aws-gcp-federation (vertex.tf). 323586397743 is ogenki-435905's
# project number.
gcp_project_id          = "ogenki-435905"
gcp_vertex_wif_audience = "//iam.googleapis.com/projects/323586397743/locations/global/workloadIdentityPools/aws-workloads/providers/aws-account"
