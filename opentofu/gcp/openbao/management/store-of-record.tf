# Stage 2 on GCP (docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md,
# ADR-0037): the same mounts, policies and logins AWS defines, from the shared
# module. Until this existed, jwt/gcp-0's external-secrets role named a policy
# no GCP OpenBao ever had, and the 14 OpenBao-backed ExternalSecrets on gcp-0
# authenticated and then read nothing.

# OIDC is gated on the `openbao-oidc` entry EXISTING, not on the variable
# being set. Reading a version of a missing secret is a hard error; listing
# first turns "ZITADEL not bootstrapped yet" into "OIDC off", so a first deploy
# converges and the second apply after zitadel-oidc-clients.sh picks it up --
# the same two-pass shape as opentofu/aws/openbao/management/oidc.tf.
#
# The gate checks that the SECRET exists, not that it has a VERSION -- the
# provider has no version-listing data source. zitadel-oidc-clients.sh writes on
# GCP as create + versions add, so a failed add leaves a version-less secret and
# this plan then fails on "latest" not found. Recovery: add the version (re-run
# zitadel-oidc-clients.sh sync --apply) or delete the empty secret
# (gcloud secrets delete openbao-oidc --project <id>), then re-apply.
data "google_secret_manager_secrets" "openbao_oidc" {
  count   = var.openbao_oidc_secret_id == "" ? 0 : 1
  project = var.project_id
  # Not an exact match in Secret Manager's list filter; contains() below is.
  filter = "name:${var.openbao_oidc_secret_id}"
}

locals {
  oidc_secret_present = var.openbao_oidc_secret_id != "" && contains(
    [for s in try(data.google_secret_manager_secrets.openbao_oidc[0].secrets, []) : s.secret_id],
    var.openbao_oidc_secret_id
  )
}

data "google_secret_manager_secret_version" "openbao_oidc" {
  count   = local.oidc_secret_present ? 1 : 0
  secret  = var.openbao_oidc_secret_id
  project = var.project_id
}

locals {
  oidc_raw           = try(jsondecode(data.google_secret_manager_secret_version.openbao_oidc[0].secret_data), {})
  oidc_client_id     = try(local.oidc_raw["client_id"], "")
  oidc_client_secret = try(local.oidc_raw["client_secret"], "")
  # Falls back to the `endpoint` the registration script stores alongside the
  # credentials, so the IdP hostname is not configured twice.
  oidc_issuer = var.openbao_oidc_issuer != "" ? var.openbao_oidc_issuer : try(local.oidc_raw["endpoint"], "")
}

module "store_of_record" {
  source = "../../../shared/modules/openbao-store-of-record"

  pki_mount_path     = vault_mount.pki.path
  openbao_address    = local.openbao_address
  admin_username     = var.admin_username
  admin_group_alias  = "platform"
  secret_owning_apps = var.secret_owning_apps
  oidc_client_id     = local.oidc_client_id
  oidc_client_secret = local.oidc_client_secret
  oidc_issuer        = local.oidc_issuer
}

# Published so an operator can retrieve the break-glass password -- the GCP
# twin of opentofu/aws/openbao/management/secrets.tf. Google-managed key,
# matching the AVD-AWS-0098 decision recorded in .trivyignore.yaml.
resource "google_secret_manager_secret" "admin_credentials" {
  project   = var.project_id
  secret_id = var.admin_credentials_secret_name

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "admin_credentials" {
  secret = google_secret_manager_secret.admin_credentials.id
  secret_data = jsonencode({
    username = var.admin_username
    password = module.store_of_record.admin_password
    address  = local.openbao_address
  })
}
