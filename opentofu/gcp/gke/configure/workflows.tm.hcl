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
#   Each job below checks $TM_CLOUD first and no-ops with a [skip]
#   message when it's unset or not "true".
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
#   the literal `${...}` must reach bash. `${global.provisioner}` interpolations
#   are intentional (Terramate-evaluated -> "tofu").
#
# Usage:
#   terramate script run deploy                      # skipped
#   TM_CLOUD=gcp terramate script run deploy   # runs

script "deploy" {
  name        = "GKE Configure Deployment (Stage 2)"
  description = "Apply the Gateway API CRDs, then install Cilium and Flux"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        # The vault provider (openbao.tf) needs the CA chain on disk before init.
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
        ${global.provisioner} init
        ${global.provisioner} validate
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'
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
        ${global.cloud_gate}
        set -euo pipefail
        # The vault provider (openbao.tf) needs the CA chain on disk before init.
        bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
        ${global.provisioner} init
        ${global.provisioner} validate
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'
      BASH
      ],
    ]
  }
}

script "destroy" {
  name        = "GKE Configure Destroy"
  description = "Attempt to remove Cilium and Flux; never blocks the cluster teardown"

  # THIS SCRIPT MUST NOT FAIL THE RUN, and that is the whole point of it.
  #
  # Everything this stack manages lives INSIDE the cluster that gke/init deletes
  # moments later, so its teardown is a tidiness step and never a prerequisite.
  # It used to run a bare `tofu destroy` under `set -euo pipefail`. Because
  # `terramate script run --reverse destroy` visits this stack BEFORE gke/init,
  # any failure here aborted the run before the billable resource was touched --
  # leaving a live GKE cluster with no workflow path to remove it.
  #
  # Measured 2026-08-24: a teardown ~63 minutes after cluster creation failed
  # with
  #
  #   Error: flux-system/gke-gcp-0-vars failed to delete kubernetes
  #          resource: Unauthorized
  #
  # because the helm and kubectl providers hold a GCP access token acquired at
  # plan time and it had expired. The cluster and both static nodes were still
  # RUNNING afterwards. The usual reasons are worse: a broken cluster, or a
  # private endpoint unreachable because the tailnet is down -- exactly when a
  # teardown is most needed.
  #
  # gke/init's own destroy already solved this with the attempt/reconcile split;
  # the fix simply never reached the --reverse path, so the hole reopened through
  # a different door. Same helper, same contract, so the two entry points cannot
  # drift apart again.
  #
  # State is deliberately NOT cleared here. At this point the cluster may still
  # exist, so state may still be accurate; gke/init's `reconcile` job drops what
  # is left only after the cluster is provably gone.
  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # The CA fetch is BEST-EFFORT here, and only here -- deploy and preview
        # above keep it strict, because there the vault provider must configure
        # for the apply to mean anything.
        #
        # On the destroy path it is the opposite. `write_ca` in
        # openbao-config.sh exits non-zero on four paths -- secret unreadable,
        # empty value, mkdir failure, non-PEM content -- and an expired ADC
        # reaches the first of them. Under the `set -euo pipefail` above, that
        # aborts this script BEFORE destroy-stage2.sh runs, which is precisely
        # the 2026-08-24 failure this script's header memorialises: a stale
        # credential left a live GKE cluster with no workflow path to remove it.
        # AWS hit the same shape and was corrected -- see the long comment in
        # opentofu/aws/openbao/cluster/workflows.tm.hcl about a CA fetch
        # hard-blocking a destroy "with the documented override having no
        # effect".
        #
        # Nothing downstream requires the CA: `destroy-stage2.sh attempt`
        # already tolerates a provider-configure failure, so a missing CA
        # degrades this run from "removed the in-cluster objects" to "left them
        # for gke/init to delete with the cluster" -- which is the same
        # outcome either way, moments later.
        if ! bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem; then
          echo "[warn] CA chain fetch failed -- continuing anyway."
          echo "       The vault provider will fail to configure and destroy-stage2.sh"
          echo "       will fall through to its tolerant path. Failing here instead"
          echo "       would strand the live GKE cluster gke/init is about to delete."
        fi
        bash "${terramate.root.path.fs.absolute}/scripts/destroy-stage2.sh" \
          attempt "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/configure" \
          -var='cilium_version=${global.cilium_version}' \
          -var='gateway_api_version=${global.gateway_api_version}' \
          -var='flux_operator_version=${global.flux_operator_version}' \
          -var='flux_instance_version=${global.flux_instance_version}'
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

script "drift" "detect" {
  name        = "GCP Drift Check (opt-in)"
  description = "Detect drift in this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
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
