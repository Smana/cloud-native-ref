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
      # The CA fetch and the snapshot share ONE gate, in one bash step.
      #
      # They were two separate ungated steps, and that made
      # TM_OPENBAO_SKIP_SNAPSHOT useless for the case it exists for. The CA
      # fetch exits non-zero when the ca-chain secret is missing or unreadable,
      # and `openbao-config.sh`'s own --ca-file readability check runs during
      # argument parsing, before dispatch reaches the skip check inside
      # pre_destroy_snapshot. So a destroy of a node that is "already gone" --
      # exactly when its surrounding secrets are most likely gone too -- was
      # hard-blocked by an error about a CA chain, with the documented override
      # having no effect. The operator's only recourse was editing this file.
      #
      # The CA exists only to let the snapshot verify TLS, so if the snapshot is
      # skipped the CA is not wanted either. One gate, checked before either.
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        if [ "$${TM_OPENBAO_SKIP_SNAPSHOT:-false}" = "true" ]; then
          echo "[skip] TM_OPENBAO_SKIP_SNAPSHOT=true -- no CA fetch, no pre-destroy snapshot."
          echo "       Everything written since the last scheduled snapshot will be lost."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --root-ca-secret-name "${global.ca_chain_secret_name}" \
          --ca-output-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" pre-destroy-snapshot \
          --url "${global.openbao_url}" \
          --root-token-secret-name "${global.root_token_secret_name}" \
          --snapshot-bucket "${global.snapshot_bucket_name}" \
          --ca-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
      BASH
      ],
      [global.provisioner, "init", "-lock-timeout=5m"],
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
