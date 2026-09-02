locals {
  # WHICH ZITADEL THIS POOL FEDERATES, derived rather than pinned.
  #
  # Same expression as opentofu/gcp/gke/configure's locals.tf, and deliberately
  # so: when GCP is the primary cloud this cluster hosts its own ZITADEL at
  # auth.<public_domain_name>, and a pool trusting the AWS issuer would reject
  # every token it was shown. Hardcoding the AWS issuer here made this stack
  # silently correct for one topology and silently wrong for the other, which is
  # exactly the class of bug ADR-0027's primary_cloud global exists to remove.
  #
  # deploy_identity_provider is passed by workflows.tm.hcl from
  # global.deploy_identity_provider_gcp -- never set in variables.tfvars, where
  # it would override the derivation without saying so.
  identity_provider_url = var.deploy_identity_provider ? "https://auth.${var.public_domain_name}" : var.identity_provider_url
}

# The workforce pool is an ORGANISATION-level resource, which is why this is its
# own stack rather than part of gke/configure: a second GCP cluster shares it.
resource "google_iam_workforce_pool" "zitadel" {
  workforce_pool_id = var.workforce_pool_id
  parent            = "organizations/${var.org_id}"
  location          = "global"
  display_name      = "ogenki zitadel" # NO parentheses -- INVALID_DISPLAY_NAME
  description       = "Federates ZITADEL identities for Kubernetes RBAC on GKE"
}

resource "google_iam_workforce_pool_provider" "zitadel" {
  workforce_pool_id = google_iam_workforce_pool.zitadel.workforce_pool_id
  location          = "global"
  provider_id       = "zitadel"
  display_name      = "zitadel oidc"

  # google.groups is what makes RBAC group bindings work: ZITADEL's `groups`
  # claim (produced by scripts/zitadel-actions/groups-from-roles.js) arrives at
  # the API server as principalSet://.../group/<role>.
  attribute_mapping = {
    "google.subject"      = "assertion.sub"
    "google.groups"       = "assertion.groups"
    "google.display_name" = "assertion.email"
  }

  oidc {
    issuer_uri = local.identity_provider_url

    # The ZITADEL PROJECT id, not a per-cluster OIDC client id. ZITADEL includes
    # the project id in the aud of every token issued for that project, and STS
    # accepts it (measured 2026-09-02). Pinning the project rather than an app
    # is what lets this stack run before any OIDC client exists.
    #
    # THAT ONLY HOLDS WHEN THE PROJECT ID IS KNOWN IN ADVANCE, which is true for
    # an AWS-hosted ZITADEL because its rebuilds restore from a seed and keep
    # their ids. A GCP-primary bootstrap mints a brand-new instance with a new
    # project id, so the value cannot be committed ahead of time -- see
    # `resolve_workforce_audience` in scripts/zitadel-oidc-clients.sh, which
    # reconciles it once the project exists.
    #
    # lifecycle.ignore_changes keeps that script's update from being reverted by
    # the next apply. The alternative -- tofu overwriting the live audience with
    # a stale committed value -- fails as a bare `invalid_grant` with every
    # component reporting healthy.
    client_id = var.zitadel_project_id

    web_sso_config {
      # ID_TOKEN pairs ONLY with ONLY_ID_TOKEN_CLAIMS. The other combination
      # fails as "Invalid OIDC WebSsoConfig AssertionClaimsBehavior".
      response_type             = "ID_TOKEN"
      assertion_claims_behavior = "ONLY_ID_TOKEN_CLAIMS"
    }
  }

  lifecycle {
    # See the client_id comment above: on a GCP-primary bootstrap the correct
    # audience is not knowable until ZITADEL exists, so a post-cluster script
    # sets it. Without this, the next apply would silently put the stale
    # committed value back.
    ignore_changes = [oidc[0].client_id]
  }
}
