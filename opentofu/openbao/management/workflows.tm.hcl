# Every script that configures the Vault provider has to materialise the CA
# chain first.
#
# `providers.tf` sets `ca_cert_file = var.openbao_ca_cert_file` (default
# `.tls/ca.pem`) whenever `openbao_skip_tls_verify` is false, which is the
# default. `.tls/` is gitignored, so on a fresh checkout or any CI runner that
# file does not exist and the provider fails to configure — before it can plan.
# Only the `deploy` script below used to write it, which left the global
# `preview`, `drift detect`, `drift reconcile` and `destroy` scripts broken for
# this stack.
#
# These overrides mirror the global scripts in opentofu/workflows.tm.hcl with the
# `ca` step prepended. Pass `-var openbao_skip_tls_verify=true` for a first
# bootstrap where the CA is not in Secrets Manager yet.
globals "openbao_ca_cmd" {
  args = [
    "bash",
    "../../../scripts/openbao-config.sh",
    "ca",
    "--root-ca-secret-name",
    global.root_ca_secret_name,
    "--ca-output-file",
    ".tls/ca.pem",
    "--region",
    global.region,
    "--profile",
    global.profile,
  ]
}

script "preview" {
  name        = "OpenTofu Deployment Preview"
  description = "Create a preview of OpenTofu changes and synchronize it to Terramate Cloud"

  job {
    commands = [
      global.openbao_ca_cmd.args,
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-detailed-exitcode", "-lock=false", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "drift" "detect" {
  name        = "Opentofu Drift Check"
  description = "Detect drifts in Opentofu configuration and synchronize it to Terramate Cloud"

  job {
    commands = [
      global.openbao_ca_cmd.args,
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-detailed-exitcode", "-lock=false", "-var-file=variables.tfvars", {
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
      [global.provisioner, "apply", "-input=false", "-auto-approve", "-lock-timeout=5m", "-var-file=variables.tfvars", "drift.tfplan", {
        sync_deployment = true
        tofu_plan_file  = "drift.tfplan"
      }],
    ]
  }
}

script "destroy" {
  description = "Opentofu destroy"
  job {
    name        = "destroy"
    description = "Opentofu destroy"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # Needed even to tear down: the provider still has to configure before it
      # can plan the destroy.
      global.openbao_ca_cmd.args,
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}

script "deploy" {
  description = "Init OpenBao cluster and configure PKI"
  job {
    name        = "openbao-configure"
    description = "OpenBao configuration"
    commands = [
      # Initialize OpenBao cluster. Stores the root token and the recovery keys
      # in two separate AWS Secrets Manager entries.
      #
      # --skip-verify is still needed here: this runs against a freshly booted
      # cluster before anything has vouched for its certificate, and the
      # request carries no secret in either direction.
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "init",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--recovery-keys-secret-name",
        global.recovery_keys_secret_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--skip-verify",
      ],
      # Materialise the CA chain for the Vault provider. Has to be a script
      # step rather than a local_file resource: provider configuration is
      # evaluated before any resource exists, so the file must already be on
      # disk when `tofu init` runs.
      [
        "bash",
        "../../../scripts/openbao-config.sh",
        "ca",
        "--root-ca-secret-name",
        global.root_ca_secret_name,
        "--ca-output-file",
        ".tls/ca.pem",
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
      # Module management: Configure OpenBao (SecretsEngine, Approles, PKI, etc.)
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-lock=false", "-var-file=variables.tfvars"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars",
        {
          sync_deployment = true
          tofu_plan_file  = "out.tfplan"
        }
      ],
    ]
  }
}
