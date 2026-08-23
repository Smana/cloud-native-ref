# GCP GKE-specific Terramate scripts
#
# Two-stage deployment, split for the same reason as EKS: the helm provider needs
# a cluster endpoint at plan time, so stage 2 can only run once the cluster exists.
#
#   Stage 1 (this stack):  GKE Standard cluster, static spot node pool, Workload
#                          Identity, Crossplane WIF bootstrap
#   Stage 2 (configure):   Gateway API CRDs -> Cilium -> Flux Operator -> Flux Instance
#
# There is no stage 3. The EKS equivalent recycles bootstrap nodes whose ENIs
# predate Cilium, which is specific to ENI prefix delegation and has no GCP
# counterpart -- ipam.mode=kubernetes takes pod CIDRs from the node object.
#
# The control-plane endpoint is PRIVATE, so stage 2 must run from a machine on the
# tailnet.
#
# opt-in gate (why override the global scripts at opentofu/workflows.tm.hcl):
#   Both clouds share one Terramate run order, and this stack sorts before the
#   AWS stacks. Without a guard, `terramate script run deploy` from the
#   opentofu/ root would build GCP while it's unproven. Each job below checks
#   $TM_GCP_ENABLED first and no-ops with a [skip] message when it's unset or
#   not "true" -- jobs run independently within a script, so the guard is
#   repeated per job rather than once per script.
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`
#   and `$TF_VAR_flux_git_ref`; the literal `${...}`/`$...` must reach bash.
#   `${global.provisioner}` and `${global.cilium_version}`-style interpolations
#   are intentional (Terramate-evaluated).
#
# Usage:
#   cd opentofu/gcp/gke/init
#   TM_GCP_ENABLED=true terramate script run deploy
#   TM_GCP_ENABLED=true TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy
#   TM_GCP_ENABLED=true terramate script run deploy-stage1

script "deploy" {
  name        = "GKE Full Deployment"
  description = "Deploy the GKE cluster (Stage 1) and Cilium + Flux (Stage 2)"

  job {
    name        = "stage1-cluster"
    description = "Deploy the GKE cluster, static spot node pool and Workload Identity"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init stage1-cluster: set TM_GCP_ENABLED=true to deploy"
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

  job {
    name        = "stage2-cilium-and-flux"
    description = "Apply the Gateway API CRDs, then install Cilium and Flux"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init stage2-cilium-and-flux: set TM_GCP_ENABLED=true to deploy"
          exit 0
        fi
        set -euo pipefail
        cd ../configure
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var="flux_git_ref=$${TF_VAR_flux_git_ref}"}
      BASH
      ],
    ]
  }
}

script "deploy-stage1" {
  name        = "GKE Stage 1 Only - Cluster"
  description = "Create the GKE cluster without Cilium or Flux"

  job {
    name        = "stage1-cluster"
    description = "Deploy the GKE cluster, static spot node pool and Workload Identity"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init deploy-stage1: set TM_GCP_ENABLED=true to deploy"
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
  name        = "GKE Deployment Preview"
  description = "Preview GKE deployment changes"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init preview: set TM_GCP_ENABLED=true"
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

script "destroy" {
  name        = "GKE Full Destroy"
  description = "Destroy the GKE cluster: attempt addon teardown, delete the cluster, then reconcile stage-2 state"

  # Job order is load-bearing. Stage 2 (Cilium, Flux, Gateway API CRDs) manages
  # resources that live INSIDE the cluster, so they cease to exist the moment
  # stage 1 deletes it. Stage 2 teardown is therefore a tidiness step, NOT a
  # prerequisite -- it used to be sequenced as one, and because the helm and
  # kubectl providers both need a reachable API server, an unreachable cluster
  # (private endpoint + tailnet down, or a cluster already broken) failed the
  # job under `set -e` and stage 1 never ran. The cluster, the only billable
  # thing here, was left running with no workflow path to remove it. That is
  # what forced the 2026-08-23 teardown through gcloud by hand.
  #
  # So: attempt gracefully, delete the cluster regardless, then reconcile the
  # stage-2 state -- in that order. Reconciling only AFTER the cluster is
  # provably gone is what makes dropping those state entries safe; doing it in
  # the attempt job would empty state for resources that still exist whenever
  # the cluster destroy itself fails.

  job {
    name        = "confirm"
    description = "Single confirmation prompt, cached so --reverse destroy asks once"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init destroy (confirm): set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # Init before anything is torn down: a lock file predating a new provider
        # must fail here, not after resources have started disappearing. Same stack
        # dir as stage1-destroy-cluster, so that job inherits this init.
        ${global.provisioner} init -lock-timeout=5m
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-destroy-addons"
    description = "Attempt a graceful Cilium and Flux teardown; never blocks the cluster deletion"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init destroy (stage2-destroy-addons): set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/gke-destroy-stage2.sh" \
          attempt "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/configure" \
          -var='cilium_version=${global.cilium_version}' \
          -var='flux_operator_version=${global.flux_operator_version}' \
          -var='flux_instance_version=${global.flux_instance_version}'
      BASH
      ],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy the GKE cluster, its node pool, service account and IAM bindings"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init destroy (stage1-destroy-cluster): set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        # No tolerance here, unlike stage 2: this is the billable resource. If it
        # cannot be destroyed the run must fail loudly rather than move on to the
        # network stack and strand a live cluster behind a deleted VPC.
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-reconcile-state"
    description = "Drop any stage-2 state left behind, now that the cluster holding it is gone"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init destroy (stage2-reconcile-state): set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/gke-destroy-stage2.sh" \
          reconcile "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/configure"
      BASH
      ],
    ]
  }
}
