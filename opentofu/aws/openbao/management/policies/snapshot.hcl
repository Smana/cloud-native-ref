# Least privilege for the snapshot agent: read the raft snapshot endpoint, and
# write the one key that records when the snapshot was taken.
#
# `sys/storage/raft/configuration` used to be granted here so the job could find
# the raft leader and connect straight to its private IP. That path is gone —
# the job now goes through the NLB and relies on standby nodes forwarding the
# request to the active node — so the grant went with it.
#
# Note this policy must live in the ROOT namespace: sys/storage/raft/* is a
# restricted endpoint, callable only from root.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# The freshness marker (mounts.tf, `lineage/`). kv-v2 puts data under /data/.
# No `read` here: `bao kv put` (openbao-snapshot.sh save()) needs only
# create/update, and the one place this key IS read back -- restore()'s
# freshness check -- runs under a root token minted from the recovery keys
# after the raft restore, not under this identity, so a read grant here would
# never actually be exercised.
path "lineage/data/check_timestamp" {
  capabilities = ["create", "update"]
}
