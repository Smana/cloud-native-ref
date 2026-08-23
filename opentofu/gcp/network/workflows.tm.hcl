# GCP network — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   Both clouds share one Terramate run order, so without a guard
#   `terramate script run deploy` from the opentofu/ root builds GCP -- and
#   because this stack sorts first, it builds GCP BEFORE the AWS network.
#   The gate keeps that command an AWS one-shot while GCP is unproven.
#
# How the gate works:
#   $TM_GCP_ENABLED unset or != "true"  -> echo [skip] + exit 0 (success, so
#                                          sibling stacks are unaffected)
#   $TM_GCP_ENABLED == "true"           -> run the real sequence
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
#   the literal `${...}` must reach bash. `${global.provisioner}` interpolations
#   are intentional (Terramate-evaluated -> "tofu").
#
# Usage:
#   terramate script run deploy                                   # skipped
#   TM_GCP_ENABLED=true terramate script run deploy               # runs
#   terramate script run --no-tags=opt-in deploy                  # skipped, no env var
#
# Trade-off: these overrides lose Terramate Cloud sync metadata
# (sync_deployment / sync_preview), which are command-level annotations that do
# not compose with a single bash heredoc. Accepted while the gate is temporary;
# removing the gate restores the global scripts and their cloud sync.

script "deploy" {
  name        = "GCP Network Deployment (opt-in)"
  description = "Deploy the GCP network stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network: set TM_GCP_ENABLED=true to deploy"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "preview" {
  name        = "GCP Network Preview (opt-in)"
  description = "Preview GCP network changes when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network preview: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "drift" "detect" {
  name        = "GCP Network Drift Check (opt-in)"
  description = "Detect drift when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network drift: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} plan -out=out.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "destroy" {
  name        = "GCP Network Destroy (opt-in)"
  description = "Destroy the GCP network stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network destroy: set TM_GCP_ENABLED=true"
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
