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

# Federated Route53 path (workstream 12). route53_public_zone_id and
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

# gcp-0 hosts its OWN ZITADEL (ADR-0024), so this must be true.
#
# It is the second of two gates that have to agree, and they did not. The other
# is `spec.suspend` on clusters/gcp-0/security/zitadel.yaml, which is already
# false -- Flux deploys ZITADEL here and its TLSRoute serves
# auth.gcp.cloud.ogenki.io. Leaving this at its default `false` made
# locals.tf fall back to var.identity_provider_url, whose default names the
# aws-0 instance, so every consumer on this cluster -- Grafana, the Flux UI,
# Headlamp, OpenWebUI -- was sent to https://auth.cloud.ogenki.io.
#
# That is a live IdP only while aws-0 exists. With aws-0 torn down, SSO fails
# at the authorize step against a host that answers for someone else's cluster,
# and nothing on gcp-0 reports a problem: ZITADEL is up, the consumers are
# healthy, and they simply point somewhere else.
#
# variables.tf's own comment predicts the mirror image of this ("setting this
# true while the Kustomization stays suspended points every consumer at a
# hostname this cluster does not serve"). Same failure, opposite direction:
# nothing can enforce the pairing across OpenTofu and Flux, so both halves have
# to be flipped by hand together.
deploy_identity_provider = true

# AWS SDK region hint for the route53 solver -- NOT gcp-0's GCP region (see the
# comment on var.route53_region). Matches opentofu/shared/aws-gcp-federation's
# aws_region default and opentofu/aws/eks/configure's region.
route53_region = "eu-west-3"
