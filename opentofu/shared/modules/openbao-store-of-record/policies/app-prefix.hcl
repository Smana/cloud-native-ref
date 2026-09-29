# One app's own prefix under the apps/ mount. Rendered per app by apps.tf.
#
# kv-v2 splits the mount across several API paths; a grant on the bare app path
# alone matches nothing a client calls, because the client asks for
# `<mount>/data/<app>/<key>`.
#
# `destroy` is deliberately absent: a compromised credential must not be able to
# erase secret history. Soft-delete and undelete are enough for day-to-day work,
# and permanent destruction is an administrative act (see secrets-admin.hcl).

path "${mount}/data/${app}/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "${mount}/metadata/${app}/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "${mount}/delete/${app}/*" {
  capabilities = ["update"]
}

path "${mount}/undelete/${app}/*" {
  capabilities = ["update"]
}

# Listing the mount root, so the UI can show this app's folder. kv-v2 metadata
# listing at the top level is what renders the tree; without it the app's own
# prefix is reachable only by typing its full path.
path "${mount}/metadata" {
  capabilities = ["list"]
}

path "sys/mounts" {
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
