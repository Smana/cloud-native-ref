# GCP OpenBao cluster — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   Both clouds share one Terramate run order, so without a guard
#   `terramate script run deploy` from the opentofu/ root would build this
#   stack too. The gate keeps that command an AWS one-shot while GCP is
#   unproven.
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
  name        = "GCP OpenBao Cluster Deployment (opt-in)"
  description = "Deploy the OpenBao cluster stack when TM_CLOUD selects gcp"

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
  name        = "GCP OpenBao Cluster Preview (opt-in)"
  description = "Preview OpenBao cluster changes when TM_CLOUD selects gcp"

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
  name        = "GCP OpenBao Cluster Drift Check (opt-in)"
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

# No tolerance: starting with Task 5 this stack OWNS billable resources -- the
# OpenBao compute instance(s), load balancer and reserved address. A destroy
# that swallows failure and exits 0 would let a `terramate script run
# --reverse destroy` proceed to delete the network stack this one depends on
# (`after` in stack.tm.hcl), stranding those instances behind a deleted VPC
# with no workflow path to remove them.
#
# This is the mirror image of why opentofu/gcp/gke/configure's destroy IS
# tolerant: everything that stack manages lives INSIDE the cluster that
# gke/init deletes moments later, so its failure mode is "nothing left to
# strand". This stack has no such backstop, so it follows
# opentofu/gcp/gke/init/workflows.tm.hcl's `stage1-destroy-cluster` job
# instead: "No tolerance here ... this is the billable resource. If it cannot
# be destroyed the run must fail loudly rather than move on to the network
# stack and strand [resources] behind a deleted VPC."
#
# The KMS key ring/key are deliberately NOT in this stack's state (see
# kms.tf: they're a bootstrap prerequisite, read via data source, because
# GCP can never delete either one). Nothing here blocks a clean destroy on
# their account, so a failure now genuinely means billable compute survived
# and this run must stop.
script "destroy" {
  name        = "GCP OpenBao Cluster Destroy (opt-in)"
  description = "Destroy the OpenBao cluster stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # One last snapshot into the lineage bucket before the node goes -- the
        # in-cluster CronJob is already gone at this point of a reverse destroy.
        # Fails hard when OpenBao is unreachable; TM_OPENBAO_SKIP_SNAPSHOT=true
        # is the override for a node that is already dead.
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" pre-destroy-snapshot \
          --cloud gcp --project ogenki-435905 \
          --url https://bao.priv.gcp.ogenki.io:8200 \
          --root-token-secret-name openbao-priv-gcp-root-token \
          --snapshot-bucket ogenki-435905-ogenki-openbao-snapshot \
          --ca-file .tls/ca.pem
        ${global.provisioner} init -lock-timeout=5m
        # -refresh=false is deliberate on DESTROY: this stack reads the network
        # stack's outputs through data.terraform_remote_state, and refreshing
        # that requires the upstream state OBJECT to exist. Once the network
        # stack has been destroyed its state is empty, so no object is written
        # at all and the read fails hard with "Unable to find remote state". A
        # destroy does not need those outputs -- everything being destroyed is
        # already described by THIS stack's own state.
        ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars
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
