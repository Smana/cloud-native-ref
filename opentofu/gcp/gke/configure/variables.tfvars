project_id   = "ogenki-435905"
region       = "europe-west4"
cluster_name = "gcp-0"

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

# Federated Route53 path (workstream 12). public_domain_name is the same zone
# opentofu/shared/aws-gcp-federation looks up; route53_public_zone_id and
# route53_role_arn are that stack's outputs, copied here literally rather than
# read via terraform_remote_state. Both are fully determined by that stack's own
# code (a fixed role name + the confirmed AWS account ID; the zone ID is a
# Route53 fact, not something OpenTofu invents), so pinning them avoids a
# cross-stack remote-state read for two values that cannot actually drift
# without the federation stack's source changing too.
public_domain_name     = "cloud.ogenki.io"
route53_public_zone_id = "Z002027037R5RFCG05YY6"
route53_role_arn       = "arn:aws:iam::396740644681:role/gcp-0-route53-dns"
