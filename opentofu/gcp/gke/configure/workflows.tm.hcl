# GKE Configure - Stage 2 Terramate scripts
# Must run AFTER opentofu/gcp/gke/init (Stage 1).
#
# This stack exists as its own Terramate stack so `terramate script run deploy`
# from the repo root does not apply it bare: the root script would run
# `tofu apply` without the -var flags the init stack's stage-2 job passes.
#
# No trivy step here, matching eks/configure: this stack creates no cloud
# resources, only in-cluster ones, and has no .trivyignore.yaml.
#
# opt-in gate (why override the global scripts at opentofu/workflows.tm.hcl):
#   Both clouds share one Terramate run order, and the GCP stacks are unproven.
#   Each job below checks $TM_GCP_ENABLED first and no-ops with a [skip]
#   message when it's unset or not "true".
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
#   the literal `${...}` must reach bash. `${global.provisioner}` interpolations
#   are intentional (Terramate-evaluated -> "tofu").
#
# Usage:
#   terramate script run deploy                      # skipped
#   TM_GCP_ENABLED=true terramate script run deploy   # runs

script "deploy" {
  name        = "GKE Configure Deployment (Stage 2)"
  description = "Apply the Gateway API CRDs, then install Cilium and Flux"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE configure deploy: set TM_GCP_ENABLED=true to deploy"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "preview" {
  name        = "GKE Configure Preview"
  description = "Preview Cilium and Flux changes"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE configure preview: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "destroy" {
  name        = "GKE Configure Destroy"
  description = "Remove Cilium and Flux (WARNING: will break cluster networking)"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE configure destroy: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
        # tofu command run in a stack, so it has to init itself.
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
