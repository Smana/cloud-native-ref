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
  # project global to reference.
  # Initialise a freshly booted OpenBao, then store its root token and recovery
  # keys in Secret Manager.
  #
  # This is not optional and it is not idempotent-by-luck: a brand-new instance
  # has empty `file` storage, so it reports initialized=false and every read
  # returns `503 Vault is sealed`. Cloud KMS auto-unseal does NOT help — there is
  # nothing to unseal until `bao operator init` creates the storage. The vault
  # provider configures at PLAN time, so the failure lands before a single
  # resource is planned.
  #
  # It was missing here while opentofu/aws/openbao/management/workflows.tm.hcl
  # has run the same step as its first job all along, which is why a
  # from-scratch GCP deploy could never succeed: `terramate script run deploy`
  # reached this stack and aborted the whole run on a sealed OpenBao. It only
  # ever worked when someone had run the init by hand, which is how
  # docs/gcp-bootstrap.md came to mention a root token "written by
  # openbao-config.sh init" that no workflow wrote.
  #
  # Safe to re-run: the script health-checks first and exits 0 when OpenBao is
  # already initialised and unsealed, so this is a no-op on every deploy after
  # the first.
  #
  # --skip-verify, like the AWS side: this runs against a freshly booted cluster
  # before anything has vouched for its certificate, and carries no secret in
  # either direction.
  openbao_init = <<-EOT
    bash "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh" init \
      --url https://bao.priv.gcp.ogenki.io:8200 \
      --cloud gcp \
      --project ogenki-435905 \
      --root-token-secret-name openbao-priv-gcp-root-token \
      --recovery-keys-secret-name openbao-priv-gcp-recovery-keys \
      --skip-verify
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
  description = "Configure the PKI mount, cert-manager role and AppRole"

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
        ${global.openbao_init}
        ${global.openbao_ca_fetch}
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

script "destroy" {
  name        = "GCP OpenBao Management Destroy (opt-in)"
  description = "Remove the PKI mount, role and AppRole"

  # TOLERANT, unlike openbao/cluster's destroy -- and the distinction is the one
  # that stranded a cluster twice before it was understood.
  #
  # Almost everything this stack manages lives INSIDE an OpenBao that
  # openbao/cluster deletes moments later, so failing here would block the
  # teardown of the stack that DOES own billable compute. The usual reason to be
  # running destroy at all is that OpenBao is already unreachable.
  #
  # openbao/cluster's destroy is strict for the mirror-image reason. See its
  # workflows.tm.hcl.
  #
  # But tolerance alone leaves a hole, so the last job closes it: the AppRole
  # SECRET lives in GCP, not in OpenBao, and it holds a live secret_id. When
  # OpenBao is unreachable the provider cannot configure, `tofu destroy` aborts
  # before deleting ANYTHING -- GCP resources included -- and a tolerant script
  # would report success with that credential still in Secret Manager.
  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
      BASH
      ],
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        # Deliberately NOT set -e from here on.
        #
        # The fetch is wrapped in a FUNCTION rather than written as
        # `${"$"}{global.openbao_ca_fetch} || echo ...`. That global is a multi-line
        # snippet ending in a newline, so appending `||` to the interpolation puts
        # the operator on its own line: `syntax error near unexpected token ||`.
        # Measured 2026-08-25 -- it broke the whole `--reverse destroy` and, because
        # the failure was a bash parse error rather than a tofu error, the run
        # reported success while every GCP resource was still running.
        ca_fetch() {
          ${global.openbao_ca_fetch}
        }
        # Best-effort: without the CA the provider cannot configure and the destroy
        # below aborts before touching anything.
        if ! ca_fetch; then
          echo "[warn] CA fetch failed -- destroy will likely abort at provider configure."
        fi
        if ! ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars; then
          echo "[warn] management destroy failed -- OpenBao is probably already gone."
          echo "[warn] Continuing so the cluster stack's teardown is not blocked."
          echo "[warn] Any state left here describes objects inside a deleted server."
        fi
        exit 0
      BASH
      ],
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        # Unconditional sweep of the one resource that OUTLIVES OpenBao.
        # Runs whether or not the destroy above succeeded: if it did, this is a
        # no-op; if it aborted at provider configure, this is the only thing
        # that removes a live secret_id from the project.
        if gcloud secrets describe openbao-priv-gcp-approle-cert-manager \
             --project ogenki-435905 >/dev/null 2>&1; then
          echo "[sweep] deleting openbao-priv-gcp-approle-cert-manager"
          gcloud secrets delete openbao-priv-gcp-approle-cert-manager \
            --project ogenki-435905 --quiet || \
            echo "[warn] sweep failed -- delete it by hand, it holds a live secret_id."
        fi
        exit 0
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
