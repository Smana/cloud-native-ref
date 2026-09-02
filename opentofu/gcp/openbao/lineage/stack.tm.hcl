stack {
  name        = "GCP OpenBao lineage"
  description = "What a rebuilt GCP OpenBao needs to come back, plus the cross-cloud plumbing: the snapshot bucket (also the mirror target for AWS snapshots), the node and CI identities, the Storage Transfer job pulling S3, and the GitHub WIF pool. Persistent -- never destroyed by the default destroy script"
  id          = "8e1a52d4-3b7f-4c66-9a0d-2f5e7c1b9a3d"

  # No `after`: nothing here needs the network. openbao/cluster lists this stack
  # in its own `after`.

  tags = [
    "gcp",
    "openbao",
    "openbao-lineage",
    "security",
    "persistent",
    # See opentofu/gcp/network/stack.tm.hcl -- REMOVE THIS TAG AND THE GUARDS
    # once GCP works end to end.
    "opt-in",
  ]
}
