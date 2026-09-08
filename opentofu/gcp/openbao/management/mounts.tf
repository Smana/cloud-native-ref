# Root-namespace kv-v2 mount for lineage bookkeeping -- the snapshot freshness
# marker `check_timestamp`, written by the snapshot job before every snapshot
# and read by a restore. Same mount, same path as AWS, so one script serves
# both clouds.
resource "vault_mount" "lineage" {
  path        = "lineage"
  type        = "kv-v2"
  description = "Lineage bookkeeping: the snapshot freshness marker"
}
