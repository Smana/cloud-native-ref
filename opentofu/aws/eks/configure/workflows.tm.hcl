# EKS Configure - Stage 2 Terramate scripts
# Must be run AFTER opentofu/aws/eks/init (Stage 1) completes
#
# This stage:
# 1. Disables VPC CNI and kube-proxy via DaemonSet patches
# 2. Installs Cilium CNI with kube-proxy replacement
# 3. Cilium's unmanagedPodWatcher restarts pods to get Cilium networking
# 4. Installs Flux Operator and Instance
#
# EVERY script here that runs `tofu plan` or `tofu apply` has to materialise the
# CA chain first, and that is why there are four overrides below rather than two.
#
# openbao.tf configures the `vault` provider, which verifies the server against
# `.tls/ca.pem`. `.tls/` is gitignored, so on a fresh checkout or any CI runner
# that file does not exist and the provider fails to CONFIGURE -- before it can
# plan. Provider configuration is evaluated before any resource exists, so this
# cannot be a `local_file` resource; it has to be a script step.
#
# `deploy` and `preview` carried the fetch as a duplicated 8-line literal and the
# inherited `drift detect` / `drift reconcile` from opentofu/workflows.tm.hcl had
# no fetch at all, so both drift scripts were broken for this stack the moment
# openbao.tf landed. Same failure, same fix and same shape as
# opentofu/aws/openbao/management/workflows.tm.hcl: one global, reused.
#
# The overrides also have to pass the four version variables. They have no
# defaults in variables.tf (deliberately -- see the deploy job's comment), so the
# inherited `drift detect` would fail on missing required variables even with the
# CA on disk. `drift reconcile` does not repeat them: it applies a saved
# drift.tfplan, which already carries the values.
#
# `destroy` is NOT overridden here -- see the note above that script.
globals "openbao_ca_cmd" {
  args = [
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
    "--tm-run",
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
    "ca",
    "--root-ca-secret-name",
    global.ca_chain_secret_name,
    "--ca-output-file",
    ".tls/ca.pem",
    "--region",
    global.region,
    "--profile",
    global.profile,
  ]
}

script "deploy" {
  name        = "EKS Configure Deployment (Stage 2)"
  description = "Install Cilium CNI and Flux GitOps"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      # The vault provider (openbao.tf) verifies OpenBao against the CA chain,
      # which must be on disk before `tofu init` -- see the file header.
      global.openbao_ca_cmd.args,
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
      # The vault provider (openbao.tf) verifies OpenBao against the CA chain,
      # which must be on disk before `tofu init` -- see the file header.
      global.openbao_ca_cmd.args,
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

# `drift detect` and `drift reconcile` mirror the global scripts in
# opentofu/workflows.tm.hcl with the CA fetch prepended -- and, for detect, the
# four version variables added. Both run tofu against the `vault` provider, so
# both were broken here without the fetch; see the file header.
script "drift" "detect" {
  name        = "Opentofu Drift Check"
  description = "Detect drifts in Opentofu configuration and synchronize it to Terramate Cloud"

  job {
    commands = [
      global.openbao_ca_cmd.args,
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-detailed-exitcode", "-lock=false", "-var-file=variables.tfvars",
        "-var=cilium_version=${global.cilium_version}",
        "-var=gateway_api_version=${global.gateway_api_version}",
        "-var=flux_operator_version=${global.flux_operator_version}",
        "-var=flux_instance_version=${global.flux_instance_version}", {
          sync_drift_status = true
          tofu_plan_file    = "out.tfplan"
      }],
    ]
  }
}

script "drift" "reconcile" {
  name        = "Opentofu Drift Reconciliation"
  description = "Reconcile drifts in all changed stacks"

  job {
    commands = [
      global.openbao_ca_cmd.args,
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      # DIVERGES from the eight other copies of this script, deliberately, on two
      # points -- because this override exists to make `drift reconcile` work in
      # this stack, and mirroring a script that cannot run would achieve nothing.
      #
      #   1. No `-var-file`. `tofu apply -help`: "If you don't provide a saved
      #      plan file then this command will also accept all of the
      #      plan-customization options" -- so passing one WITH a saved plan is
      #      rejected. Applying a plan takes its variable values from the plan,
      #      which also covers the four version vars `drift detect` passes above.
      #   2. `out.tfplan`, the name `drift detect` actually writes. The other
      #      copies apply `drift.tfplan`, which nothing in this repo creates.
      #
      # Either one alone makes the command fail, so `drift reconcile` has never
      # run anywhere here. Fixing the other eight is a separate change: it
      # touches every stack, and the script runs `apply -auto-approve`.
      [global.provisioner, "apply", "-input=false", "-auto-approve", "-lock-timeout=5m", "out.tfplan", {
        sync_deployment = true
        tofu_plan_file  = "out.tfplan"
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
