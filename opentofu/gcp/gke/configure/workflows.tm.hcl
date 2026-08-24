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
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'
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
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'
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
        # -refresh=false is deliberate on DESTROY.
        #
        # This stack reads another stack's outputs through
        # data.terraform_remote_state. Refreshing that data source requires the
        # upstream state OBJECT to exist -- and once the upstream stack has been
        # destroyed its state is empty, so no object is written at all and the
        # read fails hard with
        #
        #   Error: Unable to find remote state
        #   No stored state was found for the given workspace in the given backend.
        #
        # A destroy does not need those outputs: everything being destroyed is
        # already described by THIS stack's state, and the data source's last
        # value is cached there. Refreshing only adds a way for teardown to fail.
        #
        # Hit for real on 2026-08-23, when the network stack was destroyed before
        # this one and the teardown could not proceed without it.
        ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'
      BASH
      ],
    ]
  }
}

script "init" {
  name        = "GCP Init (opt-in)"
  description = "Initialize this GCP stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.gcp_gate}
        set -euo pipefail
        ${global.provisioner} init
      BASH
      ],
    ]
  }
}

script "drift" "detect" {
  name        = "GCP Drift Check (opt-in)"
  description = "Detect drift in this GCP stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.gcp_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} plan -out=drift.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

# The global version of this script runs `tofu apply -auto-approve`. Ungated, a
# drift reconcile from opentofu/ would BUILD this GCP stack without anyone
# opting in -- which is the whole reason the missing overrides were a problem
# rather than an inconsistency.
script "drift" "reconcile" {
  name        = "GCP Drift Reconciliation (opt-in)"
  description = "Reconcile drift in this GCP stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.gcp_gate}
        set -euo pipefail
        ${global.provisioner} apply -input=false -auto-approve -lock-timeout=5m -var-file=variables.tfvars drift.tfplan
      BASH
      ],
    ]
  }
}

script "opentofu" "render" {
  name        = "GCP Show Plan (opt-in)"
  description = "Render this GCP stack's plan when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.gcp_gate}
        set -euo pipefail
        echo "Stack: ${terramate.stack.path.absolute}"
        ${global.provisioner} show -no-color out.tfplan
      BASH
      ],
    ]
  }
}
