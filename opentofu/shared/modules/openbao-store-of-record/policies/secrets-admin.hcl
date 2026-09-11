# Full control of both secret mounts, for platform administrators.
#
# kv-v2 splits one logical mount across several API paths: values under `data/`,
# version history and soft-deletes under `metadata/`, `delete/`, `undelete/` and
# `destroy/`. A grant on `platform/*` alone is the classic kv-v2 mistake -- it
# reads correctly and matches nothing a client actually calls, because the
# client asks for `platform/data/<path>`.
#
# Unlike the per-app policies, this one DOES carry `destroy`: erasing a secret's
# history is an administrative act, and someone has to be able to do it.

path "platform/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "platform/metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "platform/delete/*" {
  capabilities = ["update"]
}

path "platform/undelete/*" {
  capabilities = ["update"]
}

path "platform/destroy/*" {
  capabilities = ["update"]
}

path "platform/config" {
  capabilities = ["read", "update"]
}

path "apps/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "apps/metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "apps/delete/*" {
  capabilities = ["update"]
}

path "apps/undelete/*" {
  capabilities = ["update"]
}

path "apps/destroy/*" {
  capabilities = ["update"]
}

path "apps/config" {
  capabilities = ["read", "update"]
}

# Listing the mounts themselves, so the UI can render the secrets tree.
path "sys/mounts" {
  capabilities = ["read"]
}
