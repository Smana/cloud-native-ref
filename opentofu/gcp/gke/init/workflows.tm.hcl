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
# Usage:
#   cd opentofu/gcp/gke/init
#   terramate script run deploy
#   TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy
#   terramate script run deploy-stage1

script "deploy" {
  name        = "GKE Full Deployment"
  description = "Deploy the GKE cluster (Stage 1) and Cilium + Flux (Stage 2)"

  job {
    name        = "stage1-cluster"
    description = "Deploy the GKE cluster, static spot node pool and Workload Identity"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }

  job {
    name        = "stage2-cilium-and-flux"
    description = "Apply the Gateway API CRDs, then install Cilium and Flux"
    commands = [
      ["bash", "-c", "cd ../configure && ${global.provisioner} init -lock-timeout=5m"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var=\"flux_git_ref=$${TF_VAR_flux_git_ref}\"}"],
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
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}

script "preview" {
  name        = "GKE Deployment Preview"
  description = "Preview GKE deployment changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "GKE Full Destroy"
  description = "Destroy the GKE cluster: addons (Stage 2) first, then the cluster (Stage 1)"

  job {
    name        = "confirm"
    description = "Single confirmation prompt, cached so --reverse destroy asks once"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # Init before anything is torn down: a lock file predating a new provider
      # must fail here, not after resources have started disappearing. Same stack
      # dir as stage1-destroy-cluster, so that job inherits this init.
      [global.provisioner, "init", "-lock-timeout=5m"],
    ]
  }

  job {
    name        = "stage2-destroy-addons"
    description = "Destroy Cilium and Flux (configure stack)"
    commands = [
      ["bash", "-c", "cd ../configure && ${global.provisioner} init -lock-timeout=5m"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'"],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy the GKE cluster"
    commands = [
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
