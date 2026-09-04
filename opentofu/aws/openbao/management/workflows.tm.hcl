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
    "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
    "--tm-run",
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
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
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
      # tofu command run in a stack, so it has to init itself. Without this a lock
      # file predating a new provider fails the whole `--reverse destroy` sweep.
      [global.provisioner, "init", "-lock-timeout=5m"],
      # Needed even to tear down: the provider still has to configure before it
      # can plan the destroy.
      global.openbao_ca_cmd.args,
      # Same #3411 race on the way down — mounts and namespaces are deleted
      # concurrently otherwise. See the apply job below.
      #
      # Wrapped (#1964): every `vault_*` resource here lives INSIDE the OpenBao
      # cluster, which opentofu/aws/openbao/cluster destroys immediately after
      # this stack in the reverse walk. By then `bao.priv.aws.ogenki.io` no
      # longer resolves, so the provider cannot delete them and terramate's
      # --reverse walk halts — stranding the OpenBao cluster, the network and
      # the shared stacks. Measured 2026-09-02: two teardowns reported success
      # while a NAT gateway and two instances kept running.
      #
      # The wrapper only drops `vault_*` on failure. The aws_secretsmanager_*
      # secrets and random_password in this same state are real resources, do
      # not match, and tofu still has to delete them.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run",
        "bash", "${terramate.root.path.fs.absolute}/scripts/tofu-destroy-contained.sh",
        "--contained-prefix", "vault_", "--",
      "-auto-approve", "-parallelism=1", "-var-file=variables.tfvars"],
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
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
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
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
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
      # -parallelism=1 is load-bearing, not caution.
      #
      # OpenBao 2.6.x carries openbao/openbao#3411 — inconsistent lock ordering
      # between the core mounts lock and the namespace lock. When this stack
      # writes namespaces, auth backends and mounts concurrently, a nested
      # acquire wedges the core: every write hangs, `bao status` times out even
      # on 127.0.0.1, and the apply dies with `context deadline exceeded`.
      #
      # It needs BOTH concurrency and a small node, which is why it looks
      # intermittent — reproduced locally against 2.6.2 on file storage, and the
      # deciding variable is CPU:
      #
      #   unconstrained, -parallelism=10  -> applies clean, 0 deadlocks
      #   1 core + GOMAXPROCS=2, -p=10    -> 3 deadlock markers, core wedged
      #   1 core + GOMAXPROCS=2, -p=1     -> applies clean, 0 deadlocks
      #
      # The dev cluster is a t3.micro, which is exactly the second row. Serialising
      # this stack removes the race without pinning OpenBao to an old release.
      # Raise this only after #3411 closes, and re-run the repro before you do.
      [global.provisioner, "apply", "-auto-approve", "-parallelism=1", "-var-file=variables.tfvars",
        {
          sync_deployment = true
          tofu_plan_file  = "out.tfplan"
        }
      ],
    ]
  }
}
