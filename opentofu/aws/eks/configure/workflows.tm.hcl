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

# Deliberately a no-op. This stack IS destroyed -- by eks/init's "EKS Full
# Destroy", whose `stage2-destroy-addons` job runs `tofu destroy` in this
# directory at the right moment.
#
# It used to destroy itself here, and that made `terramate script run --reverse
# destroy` from opentofu/ unsafe. The reverse walk visits this stack FIRST
# (stack.tm.hcl: `after = ["/opentofu/aws/eks/init"]`), so Cilium and Flux came
# down raw: Flux never suspended, admission webhooks left admitting, PVCs,
# NodePools and IAM access keys never cleaned. eks/init's prepare-destroy job
# then ran against a cluster whose networking was already gone. The teardown
# guide carried a warning telling people not to use the one command that ought
# to work.
#
# Sequencing this correctly is not something the stack graph can express -- the
# ordering the cluster needs is the opposite of the dependency ordering -- so
# ownership sits in one place, eks/init, and this stack defers to it.
#
# Destroying ONLY Cilium and Flux is not a real operation anyway: it breaks
# cluster networking and leaves an EKS cluster nothing can reconcile. If you
# genuinely want it, run tofu directly in this directory and pass the four
# version variables, which have no defaults.
script "destroy" {
  name        = "EKS Configure Destroy (handled by eks/init)"
  description = "No-op: eks/init's destroy tears this stack down in the correct order"

  job {
    commands = [
      ["echo", "[skip] eks/configure is destroyed by eks/init's `stage2-destroy-addons` job."],
      ["echo", "       Run: cd opentofu/aws/eks/init && terramate script run destroy"],
    ]
  }
}
