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

# policy-bot's App secret (SP3 R44): read only by merge-gate's SecretStore, through the
# merge-gate-secrets policy and JWT role. A mount of its own for the same reason as agents/.
resource "vault_mount" "merge_gate" {
  path        = "merge-gate"
  type        = "kv-v2"
  description = "policy-bot's GitHub App secret, read only by merge-gate's SecretStore (SP3 R44)"
}
