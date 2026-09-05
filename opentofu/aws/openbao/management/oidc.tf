# Human authentication: ZITADEL OIDC, authorised by project roles (ADR-0034)
# ---------------------------------------------------------------------------
# Operators log in as themselves rather than sharing the `userpass` admin. The
# policies they get come from ZITADEL project roles, which the `groupsFromRoles`
# Action flattens into a `groups` claim -- the same claim Grafana, Headlamp, the
# Flux UI and Harbor already read.
#
# The `userpass` login in auth.tf STAYS, and deleting it would be a mistake
# rather than a cleanup. Stage 2 of ADR-0033 makes ZITADEL's own masterkey an
# OpenBao secret; if ZITADEL is broken and the secret that fixes it lives here,
# an operator holding only an OIDC login has no way in. The boot path is fine
# either way (ExternalSecrets authenticates over `jwt/<cluster>`, no human
# involved) -- it is the RECOVERY path that needs a credential not mediated by
# the thing being recovered.
#
# Everything here is `count`-gated on the client id being present, so a cluster
# whose ZITADEL has not been bootstrapped yet applies cleanly with no OIDC
# method rather than failing. `scripts/zitadel-oidc-clients.sh` registers the
# app and writes {client_id, client_secret, endpoint} to the `openbao-oidc`
# store key; this reads it back.

data "aws_secretsmanager_secret_version" "openbao_oidc" {
  count     = var.openbao_oidc_secret_id == "" ? 0 : 1
  secret_id = var.openbao_oidc_secret_id
}

locals {
  oidc_raw = try(jsondecode(data.aws_secretsmanager_secret_version.openbao_oidc[0].secret_string), {})

  oidc_client_id     = try(local.oidc_raw["client_id"], "")
  oidc_client_secret = try(local.oidc_raw["client_secret"], "")
  # The ZITADEL issuer. Falls back to the stored `endpoint` the registration
  # script writes alongside the credentials, so this stack does not need the IdP
  # hostname configured twice.
  oidc_issuer = var.openbao_oidc_issuer != "" ? var.openbao_oidc_issuer : try(local.oidc_raw["endpoint"], "")

  oidc_enabled = local.oidc_client_id != "" && local.oidc_issuer != "" ? 1 : 0

  # BOTH callbacks, and both are required -- see ADR-0034 and the `openbao`
  # entry in scripts/zitadel-oidc-clients.sh, which must register exactly these.
  #
  # The UI path embeds the mount path TWICE: /ui/vault/auth/<mount>/oidc/callback.
  # That is why `path` below is pinned to "oidc" with a comment rather than made
  # a variable -- changing the mount silently invalidates a URI registered in a
  # different system, and the failure lands on the operator as ZITADEL's
  # "The requested redirect_uri is missing in the client configuration".
  #
  # The loopback is the CLI's; port 8250 is OpenBao's default and is not
  # configurable per-role.
  # Built from local.openbao_address (secrets.tf), which already resolves
  # `https://bao.<domain>:8200` -- so the UI callback cannot drift from the
  # address the rest of this stack talks to.
  oidc_redirect_uris = [
    "${local.openbao_address}/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
}

resource "vault_jwt_auth_backend" "oidc" {
  count = local.oidc_enabled

  # Pinned: the UI callback URI above is built from this value. See the locals.
  path               = "oidc"
  type               = "oidc"
  description        = "ZITADEL OIDC for human operators (ADR-0034)"
  oidc_discovery_url = local.oidc_issuer
  oidc_client_id     = local.oidc_client_id
  oidc_client_secret = local.oidc_client_secret

  # A LITERAL, deliberately, not a reference to the role resource below.
  #
  # Referencing it reads better and inverts the dependency: the role's `backend`
  # names this mount, so the mount must exist first, and a `default_role`
  # pointing at the resource makes terraform order the role BEFORE the mount it
  # has to be created inside. On a fresh apply that fails with
  # `no handler for route "auth/oidc/role/default"`.
  #
  # This field is only a string written into the mount's own config -- OpenBao
  # does not check that the role exists -- so a literal is correct as well as
  # acyclic. The role below takes its `backend` from this resource, which is the
  # edge that actually matters.
  default_role = "default"

  tune {
    listing_visibility = "unauth" # so the UI offers it on the login screen
    default_lease_ttl  = "1h"
    max_lease_ttl      = "8h"
    token_type         = "default-service"
  }
}

resource "vault_jwt_auth_backend_role" "oidc_default" {
  count = local.oidc_enabled

  # From the resource, not the literal "oidc": this is the edge that makes
  # terraform create the mount before the role that lives in it.
  backend   = vault_jwt_auth_backend.oidc[0].path
  role_name = "default"
  role_type = "oidc"

  allowed_redirect_uris = local.oidc_redirect_uris
  user_claim            = "email"
  # THE FIELD THAT DECIDES WHETHER ANY OF THIS WORKS.
  #
  # ZITADEL has no groups; it has project roles, emitted as a NESTED object
  # keyed by role then by org. `groupsFromRoles` flattens that into a flat
  # `groups` array, which is what this reads and what every other consumer on
  # the platform reads.
  #
  # Two silent failure modes meet here, and both look like "logged in with no
  # permissions" rather than like an error:
  #   - `projectRoleAssertion` false on the ZITADEL project -> the roles claim
  #     is absent, so `groups` is empty. ensure_project_role_assertion() in the
  #     registration script sets it; it defaults to FALSE.
  #   - the Action missing or renamed -> `groups` never gets built. ZITADEL
  #     fails the token request with "function not found", which surfaces to
  #     the user as a generic login failure.
  groups_claim    = "groups"
  bound_audiences = [local.oidc_client_id]

  # No policy here on purpose. Authorisation comes from the external group
  # bindings below, matched on the `groups` claim -- a token that carries no
  # recognised group gets the default policy and can do nothing, which is the
  # correct outcome for someone with a valid identity and no grant.
  token_policies = []
  token_ttl      = 3600
  token_max_ttl  = 28800
}

# Role -> policy, by way of an external group
# -------------------------------------------
# OpenBao matches a `groups` claim entry against the group ALIAS name, then
# grants that group's policies. `admin` is the ZITADEL project role granted by
# `zitadel-oidc-clients.sh --grant-admin <email>`.
#
# It carries both `admin` and `pki-admin` because the role vocabulary
# (admin/backend/frontend/data) is application-shaped and has no secrets-admin
# distinction -- ADR-0034 records that as a known coarseness rather than
# pretending otherwise. Splitting it means adding a role in ZITADEL first, at
# which point a second group here is a two-line change.
resource "vault_identity_group" "oidc_admin" {
  count = local.oidc_enabled

  name     = "openbao-admin"
  type     = "external"
  policies = [vault_policy.admin.name, vault_policy.pki_admin.name]
}

resource "vault_identity_group_alias" "oidc_admin" {
  count = local.oidc_enabled

  # Must equal the value that appears in the token's `groups` array, exactly.
  name           = "admin"
  mount_accessor = vault_jwt_auth_backend.oidc[0].accessor
  canonical_id   = vault_identity_group.oidc_admin[0].id
}
