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

# Enable and manage the key/value secrets engine at `secret/` path

# Manage tenant namespaces. Creating and deleting a namespace is a root-level
# operation; administering what is inside one needs a policy created in that
# namespace (see policies/app.hcl).
path "sys/namespaces"
{
  capabilities = ["list"]
}

path "sys/namespaces/*"
{
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# NOTE: there is deliberately no `secret/*` grant. The only kv-v2 mount on this
# cluster is `secret/` in the `app` tenant namespace, which this policy cannot
# reach from root. The grant that used to be here matched nothing.
# Any kv mount later created *in* root would need it back.

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
