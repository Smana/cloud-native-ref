resource "vault_mount" "app_secret" {
  namespace   = vault_namespace.app.path_fq
  path        = "secret"
  type        = "kv-v2"
  description = "Store sensitive data"
}

# Root-namespace kv-v2 mount for lineage bookkeeping. Today it holds one key,
# `check_timestamp`, written by the snapshot job before every snapshot and read
# by a restore to report the age of what it just installed. It lives in root,
# not in the `app` tenant namespace where the marker used to be, because it is
# a platform fact and because GCP has no `app` namespace.
resource "vault_mount" "lineage" {
  path        = "lineage"
  type        = "kv-v2"
  description = "Lineage bookkeeping: the snapshot freshness marker"
}
