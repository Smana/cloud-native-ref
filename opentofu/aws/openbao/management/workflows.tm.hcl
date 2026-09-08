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
#
# The step itself is `global.openbao_ca_cmd.args`, defined once in
# opentofu/config.tm.hcl. aws/eks/configure needs the identical command and
# Terramate globals are stack-local, so a block here would be a second definition
# of the same 18 lines rather than a shared one -- which is exactly what it was.

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

# Gated like the lineage stack, and for the same reason: everything this stack
# manages -- the PKI mount, auth mounts, policies, the `app` namespace, the
# lineage/ marker mount -- is lineage state that the snapshot carries. Destroying
# it at teardown would delete those from the live OpenBao moments before the
# cluster stack's pre-destroy snapshot, so the snapshot would bring back an
# empty store. The stack's OpenTofu state stays valid across rebuilds because a
# rehydrated OpenBao holds the same resources at the same paths.
script "destroy" {
  description = "Guarded: this stack's resources are lineage state. Requires TM_LINEAGE_DESTROY=true"
  job {
    name        = "destroy"
    description = "Opentofu destroy, only when TM_LINEAGE_DESTROY=true"
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/aws/openbao/management destroy: the PKI mount, auth mounts and"
          echo "       policies here are lineage state carried by the raft snapshot. Deleting them"
          echo "       now would empty the snapshot the cluster stack takes next. Set"
          echo "       TM_LINEAGE_DESTROY=true to destroy the lineage on purpose."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-run bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # CA fetch BEFORE `tofu init`, as in this file's `deploy` and in both
        # openbao/cluster stacks. The fetch is the step that can fail -- an
        # unreadable or missing ca-chain secret -- and `tofu init` is a backend
        # handshake plus a provider download. Running init first spent both on a
        # teardown that then aborted, on exactly the path the comments above say
        # must not be blocked.
        bash "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-run \
          bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
          --root-ca-secret-name "${global.ca_chain_secret_name}" --ca-output-file .tls/ca.pem \
          --region "${global.region}" --profile "${global.profile}"
        ${global.provisioner} init -lock-timeout=5m
        # Same #3411 race on the way down -- see the apply job.
        #
        # Contained destroy (#1964, kept through the lineage merge): every
        # `vault_*` resource here lives INSIDE the OpenBao cluster, which
        # opentofu/aws/openbao/cluster destroys immediately after this stack in
        # the reverse walk. By then `bao.priv.aws.ogenki.io` no longer resolves,
        # the provider cannot delete them, and terramate's --reverse walk halts
        # -- stranding the OpenBao cluster, the network and the shared stacks.
        # Measured 2026-09-02: two teardowns reported success while a NAT
        # gateway and two instances kept running.
        #
        # Only `vault_*` is ever dropped. The aws_secretsmanager_* secrets and
        # random_password in this same state are real resources, do not match
        # the prefix, and tofu still has to delete them.
        bash "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-run \
          bash "${terramate.root.path.fs.absolute}/scripts/tofu-destroy-contained.sh" \
          --contained-prefix vault_ -- \
          -auto-approve -parallelism=1 -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "deploy" {
  description = "Init OpenBao cluster and configure PKI"
  job {
    name        = "openbao-configure"
    description = "OpenBao configuration"
    commands = [
      # 1. Materialise the CA chain. Has to be a script step rather than a
      #    local_file resource: provider configuration is evaluated before any
      #    resource exists, so the file must already be on disk at `tofu init`.
      #    It also runs before rehydrate so the restore verifies the server.
      global.openbao_ca_cmd.args,
      # 2. The cheap static gates, and they run BEFORE rehydrate deliberately.
      #
      #    `tofu init` is a backend handshake plus a provider download;
      #    `validate` and `trivy config` are checks on this directory's HCL.
      #    None of the three needs a cluster, a live OpenBao, or any state.
      #    Rehydrate is their opposite: minutes of wall clock, a multi-MB
      #    snapshot download, a write into a live OpenBao, and NOT undoable.
      #
      #    They used to run after it, so a typo in a .tf file -- caught by
      #    `validate` in under a second -- discarded a completed snapshot
      #    restore. Two ordering constraints keep them from moving any earlier:
      #    `validate` needs `init`, and `init` needs the CA already on disk
      #    (step 1, and the reason it cannot be a local_file resource).
      #
      #    gcp/openbao/management's deploy is already in this order.
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      # 3. Rehydrate -- or, on the first deploy of a lineage, initialise.
      #
      #    A fresh node reports uninitialised. If the lineage bucket holds a
      #    snapshot, this initialises with throwaway shares it never stores and
      #    restores the newest one; the root token and recovery keys already in
      #    Secrets Manager belong to the restored state. If the bucket is empty,
      #    it is a plain init and the new keys are stored -- same as before.
      #    Idempotent: an initialised, unsealed node is left alone.
      [
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
        "rehydrate",
        "--url",
        global.openbao_url,
        "--root-token-secret-name",
        global.root_token_secret_name,
        "--recovery-keys-secret-name",
        global.recovery_keys_secret_name,
        "--snapshot-bucket",
        global.snapshot_bucket_name,
        "--ca-file",
        ".tls/ca.pem",
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
      # 4. Configure OpenBao (SecretsEngine, AppRoles, PKI, etc.).
      #
      #    `plan` is the first step that needs a live, unsealed OpenBao, which
      #    is why it -- and not `init`/`validate` -- sits below rehydrate. The
      #    vault provider configures at PLAN time and reads its token from
      #    Secrets Manager (providers.tf), and on a lineage's first deploy that
      #    secret is written by rehydrate.
      [global.provisioner, "plan", "-out=out.tfplan", "-lock=false", "-var-file=variables.tfvars"],
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
