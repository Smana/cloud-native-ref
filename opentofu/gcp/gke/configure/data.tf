data "terraform_remote_state" "init" {
  backend = "gcs"

  config = {
    bucket = "ogenki-435905-tfstate"
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
# now, and it moves to OpenBao once workstream 11 lands.
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

# The whole Gateway API release bundle, not a hand-picked list.
#
# cilium-operator probes for these CRDs exactly ONCE at startup and permanently
# disables its Gateway API controller if any are absent -- no crash, no alert, and
# only the leader replica logs it. On AWS this fired on 2026-08-19 over a
# two-second gap, because the hand-written list had eight entries and Cilium 1.20
# also wants BackendTLSPolicy. Enumerating them is what failed there; the bundle
# cannot drift from what Cilium expects.
#
# Experimental channel to match AWS -- one Gateway API surface on both clouds, so a
# route using an experimental field cannot work on one and fail on the other.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}
