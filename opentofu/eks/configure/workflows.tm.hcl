# EKS Configure - Stage 2 Terramate scripts
# Must be run AFTER opentofu/eks/init (Stage 1) completes
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
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
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
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
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
      [global.provisioner, "destroy", "-var-file=variables.tfvars"],
    ]
  }
}
