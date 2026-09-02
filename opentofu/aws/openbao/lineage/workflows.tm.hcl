# Lineage stacks are what survive a teardown BY DESIGN. Only `destroy` is
# overridden; deploy / preview / drift inherit the global scripts.
#
# Destroying this stack schedules the seal key for deletion. Every snapshot in
# the bucket -- and the GCS mirror of it -- becomes ciphertext the moment that
# completes, and nothing in the platform can bring OpenBao back. So the gate
# is a separate, deliberately ugly variable rather than the usual confirm
# prompt, and the message says what is about to be lost.
#
# The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
# the literal must reach bash.
script "destroy" {
  name        = "OpenBao lineage destroy (guarded)"
  description = "Destroy the seal key, snapshot bucket and drill role. Requires TM_LINEAGE_DESTROY=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/aws/openbao/lineage destroy: this stack holds the OpenBao seal"
          echo "       key and the snapshot bucket. Destroying it makes every snapshot,"
          echo "       including the GCS mirror, permanently unreadable. Set"
          echo "       TM_LINEAGE_DESTROY=true only if that is genuinely what you want."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
