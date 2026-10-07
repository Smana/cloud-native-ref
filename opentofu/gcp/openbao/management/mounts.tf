# Root-namespace kv-v2 mount for lineage bookkeeping -- the snapshot freshness
# marker `check_timestamp`, written by the snapshot job before every snapshot
# and read by a restore. Same mount, same path as AWS, so one script serves
# both clouds.
resource "vault_mount" "lineage" {
  path        = "lineage"
  type        = "kv-v2"
  description = "Lineage bookkeeping: the snapshot freshness marker"
}

# The agents' own secrets (SP2 ruling P38, external review M1; GCP parity GP-8):
# the GitHub App keys and the agents' Z.ai key. A mount of its own because
# `external-secrets` reads all of platform/ through a ClusterSecretStore any
# namespace can use (T14): only `agents-secrets` and `secrets-admin` name it.
resource "vault_mount" "agents" {
  path        = "agents"
  type        = "kv-v2"
  description = "Agent platform secrets, read only by agent-system's SecretStore (SP2 P38)"
}
