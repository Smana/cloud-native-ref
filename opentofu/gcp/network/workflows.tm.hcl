# GCP network — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   Both clouds share one Terramate run order, so without a guard
#   `terramate script run deploy` from the opentofu/ root builds GCP -- and
#   because this stack sorts first, it builds GCP BEFORE the AWS network.
#   The gate keeps that command an AWS one-shot while GCP is unproven.
#
# How the gate works:
#   $TM_CLOUD not naming gcp             -> echo [skip] + exit 0 (success, so
#                                          sibling stacks are unaffected)
#   $TM_CLOUD=gcp (or a list, or all)    -> run the real sequence
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
#   the literal `${...}` must reach bash. `${global.provisioner}` interpolations
#   are intentional (Terramate-evaluated -> "tofu").
#
# Usage:
#   terramate script run deploy                                   # skipped
#   TM_CLOUD=gcp terramate script run deploy               # runs
#   terramate script run --no-tags=opt-in deploy                  # skipped, no env var
#
# Trade-off: these overrides lose Terramate Cloud sync metadata
# (sync_deployment / sync_preview), which are command-level annotations that do
# not compose with a single bash heredoc. Accepted while the gate is temporary;
# removing the gate restores the global scripts and their cloud sync.

script "deploy" {
  name        = "GCP Network Deployment (opt-in)"
  description = "Deploy the GCP network stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
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
  description = "Preview GCP network changes when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
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
  description = "Detect drift when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
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
  description = "Destroy the GCP network stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m

        # Empty the private Cloud DNS zone first. external-dns wrote a record for
        # every HTTPRoute on the cluster and nothing removes them when the
        # cluster goes -- the controller that owned them went with it. Cloud DNS
        # then refuses to delete a non-empty zone:
        #
        #   Error 400: The container is not empty., containerNotEmpty
        #
        # which lands at the END of the destroy, after the rest of the VPC is
        # already gone, leaving the stack half-torn-down. On 2026-08-27 that meant
        # deleting twelve records by hand before this stack would destroy.
        #
        # Reads the zone name from state rather than re-deriving it, so it cannot
        # drift from the resource. Tolerated if the zone is already gone: the
        # script exits 0 when there is nothing to purge, which keeps a re-run of a
        # partially completed destroy working.
        zone="$(${global.provisioner} output -raw private_dns_zone_name 2>/dev/null || true)"
        project="$(${global.provisioner} output -raw project_id 2>/dev/null || true)"
        if [ -n "$${zone}" ] && [ -n "$${project}" ]; then
          # One line deliberately. A `\` continuation inside this heredoc reaches
          # bash as a literal backslash, so the script was invoked with that
          # backslash as its ONLY argument -- it printed usage, exited 2, and
          # `set -e` killed the destroy before tofu ran. The stack then looked
          # torn down (terramate exits non-zero at the very end) while the VPC,
          # the NAT and the Tailscale router were all still billing.
          bash "${terramate.root.path.fs.absolute}/scripts/gcp-purge-dns-records.sh" "$${zone}" "$${project}"
        else
          echo "[warn] no DNS zone in state; skipping the record purge."
        fi

        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "init" {
  name        = "GCP Init (opt-in)"
  description = "Initialize this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
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
  description = "Reconcile drift in this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} apply -input=false -auto-approve -lock-timeout=5m -var-file=variables.tfvars drift.tfplan
      BASH
      ],
    ]
  }
}

script "opentofu" "render" {
  name        = "GCP Show Plan (opt-in)"
  description = "Render this GCP stack's plan when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        echo "Stack: ${terramate.stack.path.absolute}"
        ${global.provisioner} show -no-color out.tfplan
      BASH
      ],
    ]
  }
}
