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

# NOTE: this policy previously granted on `pki/*` and `int_pki/*`. Those paths
# are gone because they cannot work from here, not because nobody holds this
# policy.
#
# They were never part of the bootstrap: `openbao-config.sh` and the Vault
# provider both authenticate with the root token, which carries the built-in
# `root` policy and bypasses ACL evaluation entirely. No named policy is
# consulted while the platform is being built.
#
# They were, however, plausibly reachable by a human. CLAUDE.md documents
# `bao auth -method=userpass username=admin`, created by hand outside this
# stack. That used to line up by accident: this policy landed in the *root*
# namespace (`vault_namespace.admin.namespace` resolves to the parent of
# `admin`, i.e. ""), and the old `openbao-config.sh pki` step created a `pki`
# mount in the root namespace too — so `pki/*` matched.
#
# Both halves of that accident are gone. This policy now lives in `admin`
# (see policies.tf), and from `admin` the path `pki/*` can match neither a
# root-namespace mount nor `pki_private_issuer` in the `admin/pki` *child*
# namespace — namespaces are an isolation boundary. Note also that the removed
# root-namespace mount never had a `vault_pki_secret_backend_role`, and a PKI
# engine cannot issue without one.
#
# To give an operator real PKI access, the policy has to be created *in*
# `admin/pki` and bound to an auth role in that same namespace. That, and
# bringing the hand-made userpass user into Terraform, is the identity work
# tracked separately.

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

# List, create, update, and delete key/value secrets
path "secret/*"
{
  capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
}

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
