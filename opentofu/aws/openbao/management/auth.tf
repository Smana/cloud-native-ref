# Platform auth, root namespace
# -----------------------------
# Machine authentication for the two clusters is the JWT method, one mount per
# cluster (`jwt/aws-0`, `jwt/gcp-0`), created by that cluster's `configure`
# stack -- opentofu/aws/eks/configure/openbao.tf and its GKE twin. It lives
# there rather than here because the mount's `oidc_discovery_url` is the EKS
# issuer, which carries a per-cluster ID that changes on every rebuild, and
# this stack runs BEFORE eks/init. The policies those roles reference stay
# here (policies.tf), so the authorisation model has one owner.
#
# The AppRole backend that used to be here (roles `snapshot-agent` and
# `cert-manager`, credentials published to Secrets Manager) is gone: a JWT
# login mints no long-lived credential, so there is nothing to store, rotate
# or leak.
#
# Resources below take no `namespace` argument — that is how the provider
# addresses the root namespace.

# Human operator login
# --------------------
# CLAUDE.md has always documented `bao auth -method=userpass username=admin`,
# but the backend and the user were created by hand — the same drift problem the
# snapshot AppRole had, on the credential with the widest reach.
#
# One login now, carrying both platform policies. The earlier layout forced one
# login per namespace, because a policy binds only within the namespace it is
# created in; collapsing the platform into root removes that.
#
# Deliberately no token_bound_cidrs here either, but for a different reason
# than machine auth. Machine auth (documented above) is bound by ServiceAccount
# subject and audience rather than by CIDR, and carries no CIDR bind of its
# own either. This login's lack of one is its own deliberate choice: the only
# route to this API is the internal NLB, so the network is already
# constrained, and a CIDR bind on the break-glass credential buys nothing
# against the risk of locking yourself out of your own secrets store.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"
}

resource "vault_generic_endpoint" "admin_user" {
  path = "auth/${vault_auth_backend.userpass.path}/users/${var.admin_username}"
  # The password is never readable back from OpenBao, so a read would always
  # look like drift.
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.admin.name, vault_policy.pki_admin.name]
    password      = random_password.admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}

# There is deliberately NO tenant auth here any more.
#
# The `app` namespace, its `secret/` kv-v2 mount, its AppRole and its policy were
# built as a worked example of tenancy and were never consumed by anything. They
# are removed rather than kept, because they were not merely unused -- they were
# unusable in the direction that matters. A policy binds only within the
# namespace it is created in, so no policy attached to a root identity group
# (which is where the OIDC groups live) could reach that mount; only a root token
# could. Leaving it in place read as the intended design rather than as the wrong
# turn it was, for anyone adding a second tenant.
#
# Application secrets live in the root-namespace `apps/` mount instead, owned per
# app through an external identity group matched on the ZITADEL `groups` claim.
# See ADR-0036 and policies/app-prefix.hcl.
