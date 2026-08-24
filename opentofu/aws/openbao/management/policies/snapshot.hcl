# Least privilege for the snapshot agent: one read, on one path.
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
