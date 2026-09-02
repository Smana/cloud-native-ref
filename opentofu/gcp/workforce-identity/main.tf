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
    issuer_uri = var.identity_provider_url

    # The ZITADEL PROJECT id, not a per-cluster OIDC client id. ZITADEL includes
    # the project id in the aud of every token issued for that project, and STS
    # accepts it (measured 2026-09-02). This is what lets this stack run before
    # scripts/zitadel-oidc-clients.sh has created any app.
    client_id = var.zitadel_project_id

    web_sso_config {
      # ID_TOKEN pairs ONLY with ONLY_ID_TOKEN_CLAIMS. The other combination
      # fails as "Invalid OIDC WebSsoConfig AssertionClaimsBehavior".
      response_type             = "ID_TOKEN"
      assertion_claims_behavior = "ONLY_ID_TOKEN_CLAIMS"
    }
  }
}
