project_id   = "ogenki-435905"
region       = "europe-west4"
cluster_name = "gcp-0"

flux_sync_url = "https://github.com/Smana/cloud-native-ref.git"

# GCP Secret Manager, not AWS Secrets Manager: reading Flux's Git credentials from
# AWS would put a hard AWS dependency in the GCP bootstrap. See data.tf for the
# expected JSON shape and how to create it.
flux_github_app_secret_name = "flux-github-app"

# cilium_version, flux_operator_version, flux_instance_version and
# gateway_api_version are deliberately NOT set here. They are passed via -var
# from the shared Terramate globals in opentofu/config.tm.hcl, so both clouds
# upgrade together.

# Federated Route53 path (ADR-0019). route53_public_zone_id and
# route53_role_arn are opentofu/shared/aws-gcp-federation's outputs, copied here
# literally rather than read via terraform_remote_state. Both are fully
# determined by that stack's own code (a fixed role name + the confirmed AWS
# account ID; the zone ID is a Route53 fact, not something OpenTofu invents),
# so pinning them avoids a cross-stack remote-state read for two values that
# cannot actually drift without the federation stack's source changing too.
#
# public_domain_name is gcp-0's OWN subdomain of that zone, not the zone's own
# name. aws-0 already runs a live wildcard Certificate for *.cloud.ogenki.io;
# requesting the identical identifier set here would collide with it on Let's
# Encrypt's Duplicate Certificate limit and on the shared _acme-challenge TXT
# record (final-branch review finding). No delegation is created -- records for
# *.gcp.cloud.ogenki.io still live in the same cloud.ogenki.io zone
# (route53_public_zone_id below is unchanged), the same way this repo already
# splits private domains per cloud (priv.aws.ogenki.io / priv.gcp.ogenki.io).
public_domain_name     = "gcp.cloud.ogenki.io"
route53_public_zone_id = "Z002027037R5RFCG05YY6"
route53_role_arn       = "arn:aws:iam::396740644681:role/gcp-0-route53-dns"

# deploy_identity_provider is NOT set here. It is derived from
# global.primary_cloud in workflows.tm.hcl, so that "which cloud hosts the
# identity provider" has exactly one answer in configuration (ADR-0027).
#
# It used to be a literal, and it was wrong: it said `true` while aws-0 also
# hosted, which is the state ADR-0027 rules out -- two user directories, where
# a grant means nothing without knowing which one issued it. Nothing could
# catch that, because the two halves of the pairing lived in different tools.
#
# The variable's own default is false, so a bare `tofu apply` in this directory
# does not silently stand up a second identity directory.
# ./scripts/validate-idp-topology.sh fails if the Flux half disagrees.

# AWS SDK region hint for the route53 solver -- NOT gcp-0's GCP region (see the
# comment on var.route53_region). Matches opentofu/shared/aws-gcp-federation's
# aws_region default and opentofu/aws/eks/configure's region.
route53_region = "eu-west-3"

# Workforce pool federating ZITADEL -- must match opentofu/gcp/workforce-identity's
# variables.tfvars verbatim. Substituted into the gcp-0 RBAC bindings; disagreement
# names a pool that does not exist and denies every user.
workforce_pool_id = "ogenki-zitadel"

# Must match zitadel_project_id in opentofu/gcp/workforce-identity, which
# pins the workforce provider audience to it.
zitadel_project_id = "388445486190712688"
