# GCP workforce identity — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   Both clouds share one Terramate run order, so without a guard
#   `terramate script run deploy` from the opentofu/ root builds GCP -- and
#   this stack has no `after`, so it can sort before the AWS stacks too. The
#   gate keeps that command an AWS one-shot while GCP is unproven -- see
#   opentofu/gcp/network/workflows.tm.hcl for the same rationale in full.
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
#   terramate script run deploy                             # skipped
#   TM_CLOUD=gcp terramate script run deploy                 # runs
#   terramate script run --no-tags=opt-in deploy             # skipped, no env var
#
# Trade-off: these overrides lose Terramate Cloud sync metadata
# (sync_deployment / sync_preview), which are command-level annotations that do
# not compose with a single bash heredoc. Accepted while the gate is temporary;
# removing the gate restores the global scripts and their cloud sync.

script "deploy" {
  name        = "GCP Workforce Identity Deployment (opt-in)"
  description = "Deploy the GCP workforce identity pool when TM_CLOUD selects gcp"

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
  name        = "GCP Workforce Identity Preview (opt-in)"
  description = "Preview GCP workforce identity changes when TM_CLOUD selects gcp"

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
  name        = "GCP Workforce Identity Drift Check (opt-in)"
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
  name        = "GCP Workforce Identity Destroy (opt-in)"
  description = "Destroy the GCP workforce identity pool when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        cat >&2 <<'WARN'
        [warn] ─────────────────────────────────────────────────────────────────
        [warn] DESTROYING THIS POOL IS NOT LIKE DESTROYING A CLUSTER.
        [warn]
        [warn] The pool id is embedded verbatim in every Kubernetes RBAC group
        [warn] string on the clusters that federate through it:
        [warn]   principalSet://iam.googleapis.com/locations/global/
        [warn]     workforcePools/<POOL>/group/<role>
        [warn] Those bindings stay schema-valid and simply match nobody, so the
        [warn] symptom is "everyone is suddenly unauthorised", with nothing
        [warn] failing or logging an error anywhere.
        [warn]
        [warn] Worse, workforce pools SOFT-DELETE with a 30-day purge: the same
        [warn] name cannot be recreated until then, so this is not a mistake you
        [warn] can undo by re-running deploy.
        [warn] ─────────────────────────────────────────────────────────────────
        WARN
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
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
