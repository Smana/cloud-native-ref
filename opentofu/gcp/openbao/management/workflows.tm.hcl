# Terramate scripts for the GCP OpenBao management stack.
#
# Every job fetches the CA chain BEFORE running tofu. That is not optional:
# the vault provider needs a reachable, initialised OpenBao at PLAN time, and
# OpenBao's certificate is issued by the offline root, which no system trust
# store knows about. Without .tls/ca.pem the provider fails on the first read
# with a TLS verification error that looks like OpenBao is down.
#
# The AWS stack does the same thing for the same reason
# (opentofu/aws/openbao/management/workflows.tm.hcl); only the --cloud flag and
# the secret name differ.
#
# opt-in gate: see opentofu/gcp/network/workflows.tm.hcl. Each job checks
# $TM_GCP_ENABLED and no-ops with a [skip] message when it is unset.

globals "openbao_ca_cmd" {
  args = [
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
    "ca",
    "--cloud",
    "gcp",
    "--project",
    # Literal rather than a global: opentofu/gcp/config.tm.hcl defines no
    # project global, and variables.tfvars carries the same literal. One more
    # place to change on a project rename, which is the trade the rest of the
    # GCP tree already makes.
    "ogenki-435905",
    "--root-ca-secret-name",
    "openbao-priv-gcp-ca-chain",
    "--ca-output-file",
    ".tls/ca.pem",
  ]
}

script "deploy" {
  name        = "GCP OpenBao Management Deploy (opt-in)"
  description = "Configure the PKI mount, cert-manager role and AppRole"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP OpenBao management deploy: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
      BASH
      ],
      global.openbao_ca_cmd.args,
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then exit 0; fi
        set -euo pipefail
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
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP OpenBao management preview: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
      BASH
      ],
      global.openbao_ca_cmd.args,
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then exit 0; fi
        set -euo pipefail
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
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
  # Everything this stack manages lives INSIDE an OpenBao that openbao/cluster
  # deletes moments later. It owns no billable resource of its own except one
  # Secret Manager entry. So its teardown is tidiness, and failing it would
  # block the teardown of the stack that DOES own billable compute. The usual
  # reason to be running destroy at all is that OpenBao is already unreachable.
  #
  # openbao/cluster's destroy is strict for the mirror-image reason. See its
  # workflows.tm.hcl.
  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP OpenBao management destroy: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
      BASH
      ],
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then exit 0; fi
        # Deliberately NOT set -e on the destroy itself.
        if ! ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars; then
          echo "[warn] management destroy failed -- OpenBao is probably already gone."
          echo "[warn] Continuing so the cluster stack's teardown is not blocked."
          echo "[warn] Any state left here describes objects inside a deleted server."
        fi
        exit 0
      BASH
      ],
    ]
  }
}

script "init" {
  name        = "GCP Init (opt-in)"
  description = "Initialize this GCP stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.gcp_gate}
        set -euo pipefail
        ${global.provisioner} init
      BASH
      ],
    ]
  }
}
