# 🤖 Configure an Approle

An **approle** in HashiCorp Vault is a machine-based authentication method. It assigns a unique RoleID and SecretID to an application or service, allowing it to securely authenticate and access specific secrets in Vault according to predefined policies.

1. Define the permissions needed by the application. Here we need to be able to take snapshots.

`policies/snapshot.hcl`

```hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
```

```hcl
resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = file("policies/snapshot.hcl")
}
```

2. Create the Approle

```hcl
resource "vault_auth_backend" "approle" {
  type = "approle"
}

resource "vault_approle_auth_backend_role" "snapshot" {
  backend           = vault_auth_backend.approle.path
  role_name         = "snapshot-agent"
  token_policies    = ["snapshot"]
  token_bound_cidrs = var.allowed_cidr_blocks
}
```

3. Retrieve the secrets that will be used by the application.

```console
export APPROLE_ROLE_ID=$(bao read --field=role_id auth/approle/role/snapshot-agent/role-id)
export APPROLE_SECRET_ID=$(bao write --field=secret_id -f auth/approle/role/snapshot-agent/secret-id)
```

We can create a token by running this command.

```console
bao write auth/approle/login role_id=${APPROLE_ROLE_ID} secret_id=${APPROLE_SECRET_ID}
```
