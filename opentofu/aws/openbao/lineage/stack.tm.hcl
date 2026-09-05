stack {
  name        = "OpenBao lineage"
  description = "What a rebuilt OpenBao needs to come back: the multi-region seal key, the snapshot bucket and its key, and the CI drill role. Persistent -- never destroyed by the default destroy script"
  id          = "5ca47693-4f30-47b3-a551-7bc20df9a40d"

  # No `after`: nothing here depends on the network. openbao/cluster lists this
  # stack in ITS `after`, which is the edge that matters.

  tags = [
    "aws",
    "openbao",
    "openbao-lineage",
    "security",
    # Read by nothing today; names the class so `terramate list --tags=persistent`
    # answers "what survives a teardown by design".
    "persistent",
  ]
}
