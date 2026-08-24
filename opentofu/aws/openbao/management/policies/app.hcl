# Read/write the tenant's own kv-v2 store. Created in the `app` namespace, so
# these paths are relative to it.
#
# kv-v2 splits one logical mount across several API paths: values live under
# `data/`, version history and soft-deletes under `metadata/`, `delete/`,
# `undelete/` and `destroy/`. A grant on `secret/*` alone is the classic kv-v2
# mistake — it reads correctly and matches nothing a client actually calls,
# because the client asks for `secret/data/<path>`.

path "secret/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list", "delete"]
}

path "secret/delete/*" {
  capabilities = ["update"]
}

path "secret/undelete/*" {
  capabilities = ["update"]
}

# Permanently destroying versions is deliberately excluded: a compromised
# application credential should not be able to erase secret history.
# Grant `secret/destroy/*` explicitly if a tenant genuinely needs it.

path "secret/config" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
