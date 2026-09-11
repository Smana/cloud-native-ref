# The following doc has been taken as reference: https://learn.hashicorp.com/tutorials/vault/policies#write-a-policy
# Added the ability to manage identities

# Read system health check
path "sys/health"
{
  capabilities = ["read", "sudo"]
}

# Create and manage ACL policies broadly across Vault

# List existing policies
path "sys/policies/acl"
{
  capabilities = ["list"]
}

# Create and manage ACL policies
path "sys/policies/acl/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Enable and manage authentication methods broadly across Vault

# Manage auth methods broadly across Vault
path "auth/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Manage identities broadly across Vault
path "identity/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# PKI is deliberately not granted here. It has its own policy, `pki-admin.hcl`,
# scoped to the real mount and templated from var.pki_mount_path. The operator
# login carries both.
#
# This policy used to grant `pki/*` and `int_pki/*`, and neither named a real
# mount. It was reachable, though — CLAUDE.md documented a hand-created userpass
# admin, and both this policy and a stray `pki` mount created by the old
# `openbao-config.sh pki` step happened to land in root, so the paths lined up
# by accident. That mount held a duplicate copy of the root CA private key and
# had no `vault_pki_secret_backend_role`, so it could not issue anything anyway.
#
# Note for anyone adding paths here: this policy lives in the root namespace, so
# a path only matches mounts in root. It cannot reach into the `app` tenant
# namespace. Manage namespaces via `sys/namespaces/*` below; manage what is
# inside one from a policy created in that namespace.

# Create, update, and delete auth methods
path "sys/auth/*"
{
  capabilities = ["create", "update", "delete", "sudo"]
}

# List auth methods
path "sys/auth"
{
  capabilities = ["read"]
}

# Manage tenant namespaces. Creating and deleting a namespace is a root-level
# operation; administering what is inside one needs a policy created in that
# namespace. No tenant namespace exists today -- the `app` one was removed with
# ADR-0036, because a policy on a root identity group could never reach into it.
path "sys/namespaces"
{
  capabilities = ["list"]
}

path "sys/namespaces/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# NOTE: there is deliberately no grant on any secret PATH here. This policy
# administers OpenBao; reading and writing the kv mounts is `secrets-admin.hcl`,
# and the operator login carries both.
#
# The warning that used to sit here -- "any kv mount later created *in* root
# would need it back" -- was right, and was then missed: `platform/` and `apps/`
# were created in root and the grant went only to the OIDC admin GROUP, so the
# break-glass userpass login could authenticate and read neither. Fixed by adding
# secrets-admin to that login in auth.tf. If you add a mount, add it to
# secrets-admin.hcl AND check auth.tf carries the policy.

# Manage secrets engines
path "sys/mounts/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# List existing secrets engines.
path "sys/mounts"
{
  capabilities = ["read"]
}
