project_id   = "ogenki-435905"
region       = "europe-west4"
cluster_name = "gcp-mycluster-0"

# Must equal flux/sources/gitrepo-gateway-api.yaml's ref.tag -- one Gateway API
# surface across both clouds.
gateway_api_version = "v1.6.1"

flux_sync_url = "https://github.com/Smana/cloud-native-ref.git"

# GCP Secret Manager, not AWS Secrets Manager: reading Flux's Git credentials from
# AWS would put a hard AWS dependency in the GCP bootstrap. See data.tf for the
# expected JSON shape and how to create it.
flux_github_app_secret_name = "flux-github-app"

# cilium_version, flux_operator_version and flux_instance_version are deliberately
# NOT set here. They are passed via -var from the shared Terramate globals in
# opentofu/config.tm.hcl, so both clouds upgrade together.
