path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# Use to identify the leader
path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}
