data "terraform_remote_state" "init" {
  backend = "gcs"

  config = {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/gke/init"
  }
}

# Short-lived OAuth token for the helm and kubectl providers.
data "google_client_config" "default" {}

# Flux's Git credentials, from GCP Secret Manager rather than AWS Secrets Manager.
#
# The AWS cluster reads these from AWS SM. Doing the same here would put a hard
# AWS dependency in the GCP bootstrap -- the GCP cluster could not come up without
# working AWS credentials, which defeats the point of a second first-class cloud.
# The design flags this as an open question; GCP Secret Manager is the answer for
# now; moving it to OpenBao is future work.
#
# PREREQUISITE, not created here: the secret must already exist and hold the same
# JSON shape the AWS side stores, i.e. the GitHub App keys Flux expects
# (githubAppID, githubAppInstallationID, githubAppPrivateKey). Create it with:
#
#   gcloud secrets create flux-github-app --replication-policy=automatic
#   gcloud secrets versions add flux-github-app --data-file=- <<'JSON'
#   {"githubAppID":"...","githubAppInstallationID":"...","githubAppPrivateKey":"..."}
#   JSON
#
# It is deliberately NOT in OpenTofu: putting real credentials in a plan or state
# is exactly what the platform's no-hardcoded-credentials rule forbids.
data "google_secret_manager_secret_version" "flux_github_app" {
  secret  = var.flux_github_app_secret_name
  project = var.project_id
}

# The GCP lineage's root token, for the vault provider.
data "google_secret_manager_secret_version" "openbao_root_token" {
  secret  = var.openbao_root_token_secret_name
  project = var.project_id
}

# This directory's ZITADEL project id when the cluster HOSTS it (GCP parity GP-4).
# A fresh directory gets a new id every build; zitadel-oidc-clients.sh publishes
# it here in stage 3. Read at plan time so this stack's later apply agrees with
# the value the sync patched into the ConfigMap. Listed before it is read: absent
# is "first build", and var.zitadel_project_id stands in until stage 3.
data "google_secret_manager_secrets" "zitadel_project" {
  count   = var.deploy_identity_provider ? 1 : 0
  project = var.project_id
  filter  = "name:zitadel-project-id"
}

data "google_secret_manager_secret_version" "zitadel_project" {
  count   = local.zitadel_project_secret_present ? 1 : 0
  secret  = "zitadel-project-id" # pragma: allowlist secret
  project = var.project_id
}
