# This cluster's way into OpenBao: the JWT auth method, validating projected
# ServiceAccount tokens against the cluster's public OIDC issuer.
#
# Why here and not in openbao/management: the EKS issuer URL carries a
# per-cluster ID that changes on every rebuild, and the management stack runs
# before eks/init. This stack already exists to bind a fresh cluster to the
# platform and runs after the issuer is known. The POLICIES the roles reference
# are the management stack's; only the mount and its roles live here.
#
# JWKS validation means OpenBao never talks to the API server -- it fetches the
# issuer's public keys over the internet -- which is what lets a REMOTE cluster
# authenticate to this OpenBao exactly the same way (opentofu/gcp/gke/configure).
# The cost: a ServiceAccount token revoked by Kubernetes stays valid until it
# expires, so role token TTLs are short.
resource "vault_jwt_auth_backend" "cluster" {
  path               = "jwt/${var.cluster_name}"
  type               = "jwt"
  description        = "Kubernetes ServiceAccount tokens from cluster ${var.cluster_name}"
  oidc_discovery_url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  bound_issuer       = data.aws_eks_cluster.this.identity[0].oidc[0].issuer

  # No mount `tune`. In hashicorp/vault v5 `tune` is a
  # `list(object({...}))` ATTRIBUTE, not a block, and its object type has eight
  # non-optional fields -- so `tune { ... }` is a syntax error and a partial
  # `tune = [{ default_lease_ttl = ... }]` fails on the fields it omits.
  # Verified against provider v5.11.0's schema on 2026-09-02. Every token this
  # mount issues comes from a role below, and those bound the TTL and the type
  # directly, so the mount-level tune bought nothing anyway.
}

locals {
  # role name => { sa, namespace, policies }. The NAMED policies below
  # (cert-manager, snapshot) are created by
  # opentofu/aws/openbao/management/policies.tf; `default` is OpenBao's
  # built-in, not one of ours -- see the note on that role.
  openbao_roles = {
    cert-manager = {
      service_account = "cert-manager"
      namespace       = "security"
      policies        = ["cert-manager"]
    }
    external-secrets = {
      service_account = "external-secrets"
      namespace       = "security"
      # `default` is NOT "the default permissions for this role" -- it is
      # OpenBao's built-in policy, which grants a token essentially nothing
      # beyond operations on itself (lookup-self, renew-self, revoke-self). This
      # role can therefore authenticate and read no secret at all. That is
      # deliberate for now: the auth contract exists and is smoke-testable, and
      # the real grant lands with the consumer. Replace this with a named policy
      # from opentofu/aws/openbao/management/policies.tf when the
      # ClusterSecretStore is repointed at OpenBao.
      policies = ["default"]
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

  backend   = vault_jwt_auth_backend.cluster.path
  role_name = each.key
  role_type = "jwt"

  # Exactly one ServiceAccount, by full subject, and exactly one audience.
  bound_audiences = [var.openbao_jwt_audience]
  bound_subject   = "system:serviceaccount:${each.value.namespace}:${each.value.service_account}"
  user_claim      = "sub"

  token_policies = each.value.policies
  token_ttl      = 600
  token_max_ttl  = 1200
  # Service tokens, which is what a workload wants: revocable and leased.
  # Set per role rather than on the mount -- see the note above.
  #
  # `service`, not `default-service`: the latter only sets the DEFAULT, so a
  # client passing `token_type=batch` on login would get an unrevocable,
  # non-leased token and the enforcement this comment describes would not exist.
  # `service` refuses the request instead.
  token_type = "service"
}
