# GKE Configure - Stage 2 Terramate scripts
# Must run AFTER opentofu/gcp/gke/init (Stage 1).
#
# This stack exists as its own Terramate stack so `terramate script run deploy`
# from the repo root does not apply it bare: the root script would run
# `tofu apply` without the -var flags the init stack's stage-2 job passes.
#
# No trivy step here, matching eks/configure: this stack creates no cloud
# resources, only in-cluster ones, and has no .trivyignore.yaml.

script "deploy" {
  name        = "GKE Configure Deployment (Stage 2)"
  description = "Apply the Gateway API CRDs, then install Cilium and Flux"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}

script "preview" {
  name        = "GKE Configure Preview"
  description = "Preview Cilium and Flux changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "GKE Configure Destroy"
  description = "Remove Cilium and Flux (WARNING: will break cluster networking)"

  job {
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
      # tofu command run in a stack, so it has to init itself.
      [global.provisioner, "init", "-lock-timeout=5m"],
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
