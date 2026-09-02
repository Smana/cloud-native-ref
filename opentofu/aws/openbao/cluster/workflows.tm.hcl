# Only `destroy` is overridden; deploy / preview / drift inherit the global
# scripts.
#
# The node's raft store is delete_on_termination. Before it goes, take one last
# snapshot into the lineage bucket so the next deploy's rehydrate brings back
# everything written since the CronJob's last run. This has to happen HERE, in
# the operator's context: `--reverse destroy` has already removed the EKS
# cluster (and the CronJob in it) by the time this stack's turn comes.
#
# The management stack's gated destroy runs before this one and does nothing,
# which is what keeps the PKI mount and policies inside this final snapshot.
script "destroy" {
  name        = "OpenBao cluster destroy (snapshot first)"
  description = "Snapshot to the lineage bucket, then destroy the cluster stack"

  job {
    name        = "destroy"
    description = "Confirm, snapshot, destroy"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # The CA chain, so the snapshot request verifies the server like every
      # other client. Writes into this stack's .tls/ (gitignored).
      [
        "bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run",
        "bash", "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh", "ca",
        "--root-ca-secret-name", global.ca_chain_secret_name,
        "--ca-output-file", ".tls/ca.pem",
        "--region", global.region,
        "--profile", global.profile,
      ],
      # Fails hard if OpenBao is unreachable. TM_OPENBAO_SKIP_SNAPSHOT=true is
      # the override for a node that is already gone.
      [
        "bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run",
        "bash", "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh", "pre-destroy-snapshot",
        "--url", global.openbao_url,
        "--root-token-secret-name", global.root_token_secret_name,
        "--snapshot-bucket", global.snapshot_bucket_name,
        "--ca-file", ".tls/ca.pem",
        "--region", global.region,
        "--profile", global.profile,
      ],
      [global.provisioner, "init", "-lock-timeout=5m"],
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
