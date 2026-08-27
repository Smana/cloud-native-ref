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
    name        = "stage2-reclaim-volumes"
    description = "Reclaim CSI-provisioned PD disks while the cluster still exists"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GKE init destroy (stage2-reclaim-volumes): set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail

        # Deleting the cluster with PVCs still bound skips the reclaim entirely:
        # the PD CSI controller dies with the cluster and every PVC-backed disk
        # is orphaned in the project with nothing left referencing it. Nothing
        # reports it -- destroy says "Destroy complete" and the disks bill on.
        # The 2026-08-27 gcp-0 teardown left three that way (20/10/5 GB), which
        # is the GCP replay of an EBS leak EKS already had a step for.
        #
        # Runs BEFORE stage2-destroy-addons on purpose: once Cilium is gone the
        # cluster's networking is unreliable, and the CSI controller needs to be
        # both running and reachable for a PVC delete to actually detach a disk.
        #
        # Never gates the teardown, for the same reason stage 2 does not: the
        # control-plane endpoint is PRIVATE, so the usual reason to be running
        # destroy is that the cluster or the tailnet is unreachable. The script
        # exits 0 when it cannot reach the cluster, and the disks it misses are
        # caught by the sweep in the network stack's destroy.
        #
        # A throwaway KUBECONFIG so a teardown never edits the operator's own
        # kubeconfig or leaves a context behind for a cluster that is about to
        # stop existing.
        KUBECONFIG="$(mktemp -t gke-teardown-kubeconfig.XXXXXX)"
        export KUBECONFIG
        trap 'rm -f "$${KUBECONFIG}"' EXIT

        name="$(${global.provisioner} output -raw cluster_name)"
        location="$(${global.provisioner} output -raw cluster_location)"
        project="$(${global.provisioner} output -raw project_id)"

        if gcloud container clusters get-credentials "$${name}" \
             --location "$${location}" --project "$${project}" 2>/dev/null; then
          bash "${terramate.root.path.fs.absolute}/scripts/k8s-reclaim-csi-volumes.sh" || true
        else
          echo "[warn] could not fetch credentials for $${name}; skipping the in-cluster"
          echo "       reclaim. Any orphaned disks are swept by the network stack destroy."
        fi
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
        ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars
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
