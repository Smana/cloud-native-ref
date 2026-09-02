# Terramate scripts for the GCP OpenBao management stack.
#
# Every job that runs tofu fetches the CA chain FIRST. That is not optional: the
# vault provider needs a reachable, initialised OpenBao at PLAN time, and
# OpenBao's certificate is issued by the offline root, which no system trust
# store knows about. Without .tls/ca.pem the provider fails on the first read
# with a TLS verification error that looks like OpenBao is down.
#
# It applies to `destroy` too. The provider still configures before it can plan a
# destroy, so a teardown without the CA aborts before deleting anything -- the
# AWS stack says the same thing at the same place.
#
# opt-in gate: see opentofu/gcp/config.tm.hcl. Every command runs inside a
# ${global.cloud_gate} block. A BARE command list cannot be gated -- each command
# in a Terramate job is its own process, so an `exit 0` in the block before it
# ends only that block. An ungated `gcloud secrets versions access` here would
# fire during a plain `terramate script run deploy` from opentofu/, which is the
# documented AWS-only path, and abort the whole run for anyone without GCP
# credentials.
globals {
  # A bash SNIPPET, not a command list, precisely so it can live INSIDE a gated
  # block. The literal project id matches variables.tfvars; opentofu/gcp has no
  # project global to reference. The snapshot bucket DOES have one --
  # `global.gcp_snapshot_bucket_name` in opentofu/config.tm.hcl -- because
  # gcp/openbao/cluster's pre-destroy snapshot is handed the same value, the way
  # the two AWS twins both read `global.snapshot_bucket_name`.
  #
  # This is not optional and it is not idempotent-by-luck: a brand-new instance
  # has empty `file` storage, so it reports initialized=false and every read
  # returns `503 Vault is sealed`. Cloud KMS auto-unseal does NOT help — there is
  # nothing to unseal until a rehydrate (or, on a first deploy, a plain init)
  # creates the storage. The vault provider configures at PLAN time, so the
  # failure lands before a single resource is planned.
  #
  # Safe to re-run: the script health-checks first and exits 0 when OpenBao is
  # already initialised and unsealed, so this is a no-op on every deploy after
  # the first.
  #
  # Rehydrate -- or, on a lineage's first deploy, initialise. The CA fetch runs
  # first so the restore verifies the server. See the AWS twin for the full
  # rationale; the only differences are the cloud flag and the GCS bucket.
  openbao_rehydrate = <<-EOT
    bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" rehydrate \
      --url https://bao.priv.gcp.ogenki.io:8200 \
      --cloud gcp \
      --project ogenki-435905 \
      --root-token-secret-name openbao-priv-gcp-root-token \
      --recovery-keys-secret-name openbao-priv-gcp-recovery-keys \
      --snapshot-bucket ${global.gcp_snapshot_bucket_name} \
      --ca-file .tls/ca.pem
  EOT

  openbao_ca_fetch = <<-EOT
    bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" ca \
      --cloud gcp \
      --project ogenki-435905 \
      --root-ca-secret-name openbao-priv-gcp-ca-chain \
      --ca-output-file .tls/ca.pem
  EOT
}

script "deploy" {
  name        = "GCP OpenBao Management Deploy (opt-in)"
  description = "Rehydrate, then configure the PKI mount, cert-manager PKI role and policies"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
      BASH
      ],
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.openbao_ca_fetch}
        ${global.openbao_rehydrate}
        # -parallelism=1 is deliberate. OpenBao 2.6.x carries openbao/openbao#3411
        # (inconsistent lock ordering across namespaces, mounts and the router),
        # which deadlocks the core when this stack writes concurrently. The
        # concurrency is ours, not OpenBao's -- so the mitigation is here rather
        # than pinning away from 2.6.x. `bao status` hanging on 127.0.0.1 means
        # core deadlock, never the VPN.
        ${global.provisioner} apply -parallelism=1 -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "preview" {
  name        = "GCP OpenBao Management Preview (opt-in)"
  description = "Preview PKI configuration changes"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
      BASH
      ],
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.openbao_ca_fetch}
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

# The global version plans with the vault provider configured, which needs the
# CA on disk and a live OpenBao. Ungated, `terramate script run drift detect`
# from opentofu/ -- an AWS maintenance command -- fails here and takes the whole
# drift sweep down with it.
script "drift" "detect" {
  name        = "GCP OpenBao Management Drift Check (opt-in)"
  description = "Detect drift when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.openbao_ca_fetch}
        ${global.provisioner} plan -out=out.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

# The global version runs `tofu apply -auto-approve`. Ungated, a drift reconcile
# from opentofu/ would CONFIGURE a GCP OpenBao without anyone opting in.
script "drift" "reconcile" {
  name        = "GCP OpenBao Management Drift Reconciliation (opt-in)"
  description = "Reconcile drift when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.openbao_ca_fetch}
        ${global.provisioner} apply -parallelism=1 -input=false -auto-approve -lock-timeout=5m -var-file=variables.tfvars drift.tfplan
      BASH
      ],
    ]
  }
}

script "opentofu" "render" {
  name        = "GCP Show Plan (opt-in)"
  description = "Render this GCP stack's plan when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        echo "Stack: ${terramate.stack.path.absolute}"
        ${global.provisioner} show -no-color out.tfplan
      BASH
      ],
    ]
  }
}

# Gated like the AWS management stack and the lineage stacks: the PKI mount,
# auth mounts, policies and the lineage/ marker mount are lineage state carried
# by the raft snapshot. Destroying them here would empty the snapshot the
# cluster stack takes next. The former tolerant destroy and its Secret Manager
# sweep are gone with the AppRole credential they existed for.
script "destroy" {
  name        = "GCP OpenBao Management Destroy (guarded, opt-in)"
  description = "Requires TM_LINEAGE_DESTROY=true: this stack's resources are lineage state"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        if [ "$${TM_LINEAGE_DESTROY:-}" != "true" ]; then
          echo "[skip] opentofu/gcp/openbao/management destroy: the PKI mount, auth mounts and"
          echo "       policies here are lineage state carried by the raft snapshot. Set"
          echo "       TM_LINEAGE_DESTROY=true to destroy the lineage on purpose."
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.openbao_ca_fetch}
        ${global.provisioner} destroy -parallelism=1 -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "init" {
  name        = "GCP Init (opt-in)"
  description = "Initialize this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
      BASH
      ],
    ]
  }
}
