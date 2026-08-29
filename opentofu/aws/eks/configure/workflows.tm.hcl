# EKS Configure - Stage 2 Terramate scripts
# Must be run AFTER opentofu/aws/eks/init (Stage 1) completes
#
# This stage:
# 1. Disables VPC CNI and kube-proxy via DaemonSet patches
# 2. Installs Cilium CNI with kube-proxy replacement
# 3. Cilium's unmanagedPodWatcher restarts pods to get Cilium networking
# 4. Installs Flux Operator and Instance

script "deploy" {
  name        = "EKS Configure Deployment (Stage 2)"
  description = "Install Cilium CNI and Flux GitOps"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      # The versions come from globals in opentofu/config.tm.hcl, the single
      # source of truth. They used to be omitted here and fall back to defaults
      # in variables.tf — which had drifted to Cilium 1.19.5 / Flux 0.53.0 while
      # the globals were on 1.20.0 / 0.55.0, so a plain `terramate script run
      # deploy` from the repo root quietly planned a CNI *downgrade* on a running
      # cluster. The defaults are gone; these flags are now required.
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
        "-var=cilium_version=${global.cilium_version}",
        "-var=gateway_api_version=${global.gateway_api_version}",
        "-var=flux_operator_version=${global.flux_operator_version}",
      "-var=flux_instance_version=${global.flux_instance_version}"],
    ]
  }
}

script "preview" {
  name        = "EKS Configure Preview"
  description = "Preview Cilium and Flux changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars",
        "-var=cilium_version=${global.cilium_version}",
        "-var=gateway_api_version=${global.gateway_api_version}",
        "-var=flux_operator_version=${global.flux_operator_version}",
        "-var=flux_instance_version=${global.flux_instance_version}", {
          sync_preview   = true
          tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "EKS Configure Destroy"
  description = "Remove Cilium and Flux (WARNING: will break cluster networking)"

  job {
    commands = [
      # Single y/n prompt; cached for 10 min so `--reverse destroy` asks once.
      # Bypass with TM_DESTROY_CONFIRMED=true for CI.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
      # tofu command run in a stack, so it has to init itself. Without this a lock
      # file predating a new provider fails the whole `--reverse destroy` sweep.
      [global.provisioner, "init", "-lock-timeout=5m"],
      # `-auto-approve`: confirmation already handled by the helper above.
      # The version variables carry no defaults, and OpenTofu requires every
      # variable to be set on destroy as well as on apply.
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars",
        "-var=cilium_version=${global.cilium_version}",
        "-var=gateway_api_version=${global.gateway_api_version}",
        "-var=flux_operator_version=${global.flux_operator_version}",
      "-var=flux_instance_version=${global.flux_instance_version}"],
    ]
  }
}
