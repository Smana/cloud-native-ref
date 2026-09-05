# This cluster's JWT auth mount on the OpenBao its Service points at. Same
# shape as opentofu/aws/eks/configure/openbao.tf -- read the rationale there.
# GKE's issuer is deterministic from project/zone/name, so this COULD live in
# the management stack; it lives here for symmetry, so "where is a cluster's
# auth mount created" has one answer.
resource "vault_jwt_auth_backend" "cluster" {
  path               = "jwt/${var.cluster_name}"
  type               = "jwt"
  description        = "Kubernetes ServiceAccount tokens from cluster ${var.cluster_name}"
  oidc_discovery_url = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"
  bound_issuer       = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"

  # No mount `tune` -- see the note in opentofu/aws/eks/configure/openbao.tf:
  # in provider v5 it is a list(object) attribute with eight non-optional
  # fields, so block syntax is invalid and a partial object is rejected. The
  # roles below bound TTL and token type instead.
}

locals {
  openbao_roles = {
    cert-manager = {
      service_account = "cert-manager"
      namespace       = "security"
      policies        = ["cert-manager"]
    }
    external-secrets = {
      service_account = "external-secrets"
      namespace       = "security"
      policies        = ["default"]
    }
    openbao-snapshot = {
      service_account = "openbao-snapshot"
      namespace       = "security"
      policies        = ["snapshot"]
    }
  }
}

resource "vault_jwt_auth_backend_role" "cluster" {
  for_each = local.openbao_roles

  backend         = vault_jwt_auth_backend.cluster.path
  role_name       = each.key
  role_type       = "jwt"
  bound_audiences = [var.openbao_jwt_audience]
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  user_claim      = "sub"
  token_policies  = each.value.policies
  token_ttl       = 600
  token_max_ttl   = 1200

  # Service tokens, which is what a workload wants: revocable and leased. Set
  # per role rather than on the mount -- see the note about `tune` above.
  #
  # `service`, not `default-service`: the latter only sets the DEFAULT, so a
  # client passing `token_type=batch` on login would get an unrevocable,
  # non-leased token and the enforcement this comment describes would not exist.
  # `service` refuses the request instead. This mount's clients are
  # `cert-manager`, `external-secrets` and `openbao-snapshot`; a compromised
  # ServiceAccount token for any of them could otherwise mint a token no
  # operator can revoke. Same value, and the same reason, as the AWS twin in
  # opentofu/aws/eks/configure/openbao.tf -- the two must not drift.
  token_type = "service"
}
