# GCP GKE-specific Terramate scripts
#
# Two-stage deployment, split for the same reason as EKS: the helm provider needs
# a cluster endpoint at plan time, so stage 2 can only run once the cluster exists.
#
#   Stage 1 (this stack):  GKE Standard cluster, static spot node pool, Workload
#                          Identity, Crossplane WIF bootstrap
#   Stage 2 (configure):   Gateway API CRDs -> Cilium -> Flux Operator -> Flux Instance
#
# There is no stage 3. The EKS equivalent recycles bootstrap nodes whose ENIs
# predate Cilium, which is specific to ENI prefix delegation and has no GCP
# counterpart -- ipam.mode=kubernetes takes pod CIDRs from the node object.
#
# The control-plane endpoint is PRIVATE, so stage 2 must run from a machine on the
# tailnet.
#
# opt-in gate (why override the global scripts at opentofu/workflows.tm.hcl):
#   Both clouds share one Terramate run order, and this stack sorts before the
#   AWS stacks. Without a guard, `terramate script run deploy` from the
#   opentofu/ root would build GCP while it's unproven. Each job below checks
#   $TM_CLOUD first and no-ops with a [skip] message when it does not name the
#   gcp lane -- jobs run independently within a script, so the guard is repeated
#   per job rather than once per script. It is `${global.cloud_gate}` in every
#   case now, never a hand-written copy.
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`
#   and `$TF_VAR_flux_git_ref`; the literal `${...}`/`$...` must reach bash.
#   `${global.provisioner}` and `${global.cilium_version}`-style interpolations
#   are intentional (Terramate-evaluated).
#
# Usage:
#   cd opentofu/gcp/gke/init
#   TM_CLOUD=gcp terramate script run deploy
#   TM_CLOUD=gcp TF_VAR_flux_git_ref='refs/heads/my-branch' terramate script run deploy
#   TM_CLOUD=gcp terramate script run deploy-stage1

script "deploy" {
  name        = "GKE Full Deployment"
  description = "Deploy the GKE cluster (Stage 1) and Cilium + Flux (Stage 2)"

  job {
    name        = "stage0-seed-secrets"
    description = "Create the generated secrets BEFORE anything can consume them"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail

        # FIRST, and deliberately before the cluster exists.
        #
        # `seed` touches only the secret store -- it iterates a static list and
        # talks to gcloud, never to Kubernetes -- so nothing forces it to wait
        # for a cluster. What DOES force it to run early is CNPG: the operator
        # applies a superuser password when it CREATES a Postgres cluster and
        # never rewrites the role afterwards. Seed after Flux has reconciled the
        # SQLInstance claim and the database is already born with a password
        # nobody holds; the ExternalSecret then syncs a credential the server
        # rejects, and no amount of fixing the secret later reaches it.
        #
        # That is not theoretical. On gcp-0, 2026-08-28: `zitadel init` failed
        # `password authentication failed for user "postgres"` on repeat, and
        # recovery needed an ALTER USER against the running database because the
        # secret had been created an hour too late.
        #
        # Harbor's role credential has the same shape, and both are unspellable
        # by hand: they carry a username as well as a password, and their key
        # separator differs per cloud.
        #
        # Not fatal if it fails -- a store that already holds these is the normal
        # case and seed skips them -- but a warning here is worth reading.
        PROJECT="$(awk -F'"' '/^project_id/{print $2}' variables.tfvars)"
        if [ -z "$${PROJECT}" ]; then
          echo "[warn] could not read project_id from variables.tfvars; skipping seed."
        else
          bash "${terramate.root.path.fs.absolute}/scripts/secret-store.sh" \
            seed --cloud gcp --project "$${PROJECT}" --apply || \
            echo "[warn] seed failed; re-run it by hand before Flux reconciles the databases"
        fi
      BASH
      ],
    ]
  }

  job {
    name        = "stage1-cluster"
    description = "Deploy the GKE cluster, static spot node pool and Workload Identity"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-cilium-and-flux"
    description = "Apply the Gateway API CRDs, then install Cilium and Flux"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        cd ../configure
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var="flux_git_ref=$${TF_VAR_flux_git_ref}"}
      BASH
      ],
    ]
  }

  job {
    name        = "stage3-secrets-and-oidc"
    description = "Grant External Secrets its per-secret access, and register the OIDC clients if this cluster hosts the IdP"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail

        # Two bootstrap steps that cannot be expressed as manifests, for the same
        # reason openbao_init cannot: they need the cluster to already be running.
        #
        #   1. External Secrets' IAM grants. gke/init grants only the bootstrap
        #      prerequisites, because a google_secret_manager_secret_iam_member
        #      needs its secret to EXIST and most of the platform's do not yet.
        #      Skipped, every ExternalSecret fails PermissionDenied and the first
        #      symptom is a HelmRelease timing out ten minutes later naming only
        #      itself.
        #
        #   2. The OIDC clients, when this cluster hosts its own ZITADEL. They
        #      live in ZITADEL's database, so a cluster that bootstraps fresh
        #      has none -- while their client ids sit stale in Secret Manager.
        #      Headlamp then never starts (CreateContainerConfigError on
        #      headlamp-envvars) and every SSO login fails.
        #
        # Both are idempotent: the grant re-applies existing bindings, and the
        # OIDC script skips apps that already exist rather than recreating them
        # (ZITADEL returns a client secret exactly once, so recreating would
        # rotate it and break a running consumer).
        #
        # Neither failing should fail the deploy -- the cluster is up and useful,
        # and both are re-runnable by hand -- so this job reports and continues.
        ROOT="${terramate.root.path.fs.absolute}"
        PROJECT="$(${global.provisioner} output -raw project_id)"
        NAME="$(${global.provisioner} output -raw cluster_name)"
        LOCATION="$(${global.provisioner} output -raw cluster_location)"
        PRIVATE_DOMAIN="$(${global.provisioner} output -raw private_domain_name)"
        # public_domain_name belongs to the CONFIGURE stack (it is a variable
        # there, not an output here), so read it from that stack's tfvars rather
        # than inventing an output. Empty would silently build "https://auth."
        # and every client would be registered against a hostname that does not
        # exist, so this is checked rather than defaulted.
        PUBLIC_DOMAIN="$(awk -F'"' '/^public_domain_name/{print $2}' ../configure/variables.tfvars)"

        KUBECONFIG="$(mktemp -t gke-bootstrap-kubeconfig.XXXXXX)"
        export KUBECONFIG
        trap 'rm -f "$${KUBECONFIG}"' EXIT

        if ! gcloud container clusters get-credentials "$${NAME}" \
               --location "$${LOCATION}" --project "$${PROJECT}" 2>/dev/null; then
          echo "[warn] could not fetch credentials for $${NAME}; skipping stage 3."
          echo "       Re-run by hand: scripts/secret-store.sh grant --cloud gcp --project $${PROJECT} --apply"
          exit 0
        fi

        echo "== granting External Secrets access to the keys this cluster asks for"
        bash "$${ROOT}/scripts/secret-store.sh" grant --cloud gcp --project "$${PROJECT}" --apply || \
          echo "[warn] grant failed; re-run it by hand"

        # Only when this cluster hosts the IdP. Consuming another cluster's
        # ZITADEL means its clients are registered there, not here.
        # Whether this cluster hosts the identity provider comes from the SAME
        # place the configure stack gets it: global.primary_cloud (ADR-0027),
        # interpolated below. The environment still overrides for one
        # invocation.
        #
        # It used to be read out of ../configure/variables.tfvars with awk, and
        # before that from $TF_VAR_deploy_identity_provider alone. Both were
        # ways of asking a second source the same question, and both got a
        # different answer than the deploy did:
        #
        #   gcp-0 shipped with `deploy_identity_provider = true` and no OIDC
        #   client ever registered. Every SSO consumer failed at the authorize
        #   step with a client_id ZITADEL had never heard of, and the deploy
        #   reported success.
        #
        # The tfvars literal no longer exists, so the awk matched nothing and
        # would have reproduced that incident exactly. One source, or none.
        DEPLOY_IDP="$${TF_VAR_deploy_identity_provider:-${global.deploy_identity_provider_gcp}}"
        if [ "$${DEPLOY_IDP}" != "true" ]; then
          # NOT hosting is not the same as nothing to do. This cluster's
          # consumers still need OIDC clients -- registered in the PRIMARY
          # cloud's directory, with THIS cluster's redirect URIs, and with the
          # resulting secrets written to THIS cluster's store where its
          # ExternalSecrets read.
          #
          # Skipping here is what left a consuming gcp-0 with no client at all:
          # oauth2-proxy came up with no secret, sat in
          # CreateContainerConfigError, and headlamp's Kustomization never went
          # ready -- the same class of failure as the never-registered-clients
          # incident above, arrived at from the opposite direction.
          #
          # The IdP URL comes from the cluster vars ConfigMap rather than being
          # rebuilt here: that is the exact value every consumer on this cluster
          # reads, so it cannot disagree with them.
          echo "== this cluster consumes ${global.primary_cloud}'s identity provider"
          CONSUMED_IDP="$(kubectl get configmap "gke-$${NAME}-vars" -n flux-system \
            -o jsonpath='{.data.identity_provider_url}' 2>/dev/null || true)"
          if [ -z "$${CONSUMED_IDP}" ]; then
            echo "[warn] could not read identity_provider_url from gke-$${NAME}-vars;"
            echo "       skipping client registration. Re-run by hand once it exists."
            exit 0
          fi

          echo "== registering this cluster's OIDC clients in $${CONSUMED_IDP}"
          IDP_URL="$${CONSUMED_IDP}" PRIVATE_DOMAIN="$${PRIVATE_DOMAIN}" \
            bash "$${ROOT}/scripts/zitadel-oidc-clients.sh" sync \
              --cluster "$${NAME}" \
              --cloud gcp --project "$${PROJECT}" \
              --idp-cloud "${global.primary_cloud}" --region "${global.region}" \
              --apply || \
            echo "[warn] OIDC registration against the primary cloud failed; re-run it by hand"

          echo "== granting access to the secrets it just created"
          bash "$${ROOT}/scripts/secret-store.sh" grant --cloud gcp --project "$${PROJECT}" --apply || true
          exit 0
        fi

        if [ -z "$${PUBLIC_DOMAIN}" ]; then
          echo "[warn] could not read public_domain_name from ../configure/variables.tfvars;"
          echo "       skipping OIDC registration rather than registering clients against"
          echo "       an empty hostname."
          exit 0
        fi

        echo "== waiting for ZITADEL (up to 15m)"
        deadline=$(( SECONDS + 900 ))
        while [ "$SECONDS" -lt "$deadline" ]; do
          if [ "$(kubectl get deploy zitadel -n security -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null; then
            break
          fi
          sleep 20
        done

        if [ "$(kubectl get deploy zitadel -n security -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -lt 1 ] 2>/dev/null; then
          echo "[warn] ZITADEL not ready in 15m; skipping OIDC client registration."
          echo "       Re-run by hand once it is up:"
          echo "         IDP_URL=https://auth.$${PUBLIC_DOMAIN} PRIVATE_DOMAIN=$${PRIVATE_DOMAIN} \\"
          echo "         scripts/zitadel-oidc-clients.sh sync --cluster $${NAME} --cloud gcp --project $${PROJECT} --apply"
          exit 0
        fi

        # The workforce provider's audience is the ZITADEL PROJECT id, which does
        # not exist until the sync below creates the project. Passing the pool
        # lets the script reconcile it; without this, per-user RBAC on this
        # cluster fails as a bare `invalid_grant` with everything looking healthy.
        # Empty (no such stack / no such key) simply skips that reconciliation.
        WORKFORCE_POOL="$(awk -F'=' '/^[[:space:]]*workforce_pool_id/{gsub(/[[:space:]"]/,"",$2); print $2}' "$${ROOT}/opentofu/gcp/workforce-identity/variables.tfvars" 2>/dev/null || true)"
        echo "== registering the OIDC clients"
        IDP_URL="https://auth.$${PUBLIC_DOMAIN}" PRIVATE_DOMAIN="$${PRIVATE_DOMAIN}" \
          bash "$${ROOT}/scripts/zitadel-oidc-clients.sh" sync \
            --cluster "$${NAME}" --cloud gcp --project "$${PROJECT}" \
            --workforce-pool "$${WORKFORCE_POOL}" --apply || \
          echo "[warn] OIDC registration failed; re-run it by hand"

        echo "== granting access to the secrets it just created"
        bash "$${ROOT}/scripts/secret-store.sh" grant --cloud gcp --project "$${PROJECT}" --apply || true
      BASH
      ],
    ]
  }
}

script "deploy-stage1" {
  name        = "GKE Stage 1 Only - Cluster"
  description = "Create the GKE cluster without Cilium or Flux"

  job {
    name        = "stage1-cluster"
    description = "Deploy the GKE cluster, static spot node pool and Workload Identity"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "preview" {
  name        = "GKE Deployment Preview"
  description = "Preview GKE deployment changes"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "destroy" {
  name        = "GKE Full Destroy"
  description = "Destroy the GKE cluster: attempt addon teardown, delete the cluster, then reconcile stage-2 state"

  # Job order is load-bearing. Stage 2 (Cilium, Flux, Gateway API CRDs) manages
  # resources that live INSIDE the cluster, so they cease to exist the moment
  # stage 1 deletes it. Stage 2 teardown is therefore a tidiness step, NOT a
  # prerequisite -- it used to be sequenced as one, and because the helm and
  # kubectl providers both need a reachable API server, an unreachable cluster
  # (private endpoint + tailnet down, or a cluster already broken) failed the
  # job under `set -e` and stage 1 never ran. The cluster, the only billable
  # thing here, was left running with no workflow path to remove it. That is
  # what forced the 2026-08-23 teardown through gcloud by hand.
  #
  # So: attempt gracefully, delete the cluster regardless, then reconcile the
  # stage-2 state -- in that order. Reconciling only AFTER the cluster is
  # provably gone is what makes dropping those state entries safe; doing it in
  # the attempt job would empty state for resources that still exist whenever
  # the cluster destroy itself fails.

  job {
    name        = "confirm"
    description = "Single confirmation prompt, cached so --reverse destroy asks once"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        # Init before anything is torn down: a lock file predating a new provider
        # must fail here, not after resources have started disappearing. Same stack
        # dir as stage1-destroy-cluster, so that job inherits this init.
        ${global.provisioner} init -lock-timeout=5m
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-reclaim-volumes"
    description = "Reclaim CSI-provisioned PD disks while the cluster still exists"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail

        # Deleting the cluster with PVCs still bound skips the reclaim entirely:
        # the PD CSI controller dies with the cluster and every PVC-backed disk
        # is orphaned in the project with nothing left referencing it. Nothing
        # reports it -- destroy says "Destroy complete" and the disks bill on.
        # The 2026-08-27 gcp-0 teardown left three that way (20/10/5 GB), which
        # is the GCP replay of an EBS leak EKS already had a step for.
        #
        # Runs BEFORE stage2-destroy-addons on purpose: once Cilium is gone the
        # cluster's networking is unreliable, and the CSI controller needs to be
        # both running and reachable for a PVC delete to actually detach a disk.
        #
        # Never gates the teardown, for the same reason stage 2 does not: the
        # control-plane endpoint is PRIVATE, so the usual reason to be running
        # destroy is that the cluster or the tailnet is unreachable. The script
        # exits 0 when it cannot reach the cluster, and the disks it misses are
        # caught by the sweep in the network stack's destroy.
        #
        # A throwaway KUBECONFIG so a teardown never edits the operator's own
        # kubeconfig or leaves a context behind for a cluster that is about to
        # stop existing.
        KUBECONFIG="$(mktemp -t gke-teardown-kubeconfig.XXXXXX)"
        export KUBECONFIG
        trap 'rm -f "$${KUBECONFIG}"' EXIT

        name="$(${global.provisioner} output -raw cluster_name)"
        location="$(${global.provisioner} output -raw cluster_location)"
        project="$(${global.provisioner} output -raw project_id)"

        if gcloud container clusters get-credentials "$${name}" \
             --location "$${location}" --project "$${project}" 2>/dev/null; then
          bash "${terramate.root.path.fs.absolute}/scripts/k8s-reclaim-csi-volumes.sh" || true
        else
          echo "[warn] could not fetch credentials for $${name}; skipping the in-cluster"
          echo "       reclaim. Any orphaned disks are swept by the network stack destroy."
        fi
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-destroy-addons"
    description = "Attempt a graceful Cilium and Flux teardown; never blocks the cluster deletion"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/destroy-stage2.sh" \
          attempt "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/configure" \
          -var='cilium_version=${global.cilium_version}' \
          -var='gateway_api_version=${global.gateway_api_version}' \
          -var='flux_operator_version=${global.flux_operator_version}' \
          -var='flux_instance_version=${global.flux_instance_version}'
      BASH
      ],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy the GKE cluster, its node pool, service account and IAM bindings"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        # No tolerance here, unlike stage 2: this is the billable resource. If it
        # cannot be destroyed the run must fail loudly rather than move on to the
        # network stack and strand a live cluster behind a deleted VPC.
        # -refresh=false is deliberate on DESTROY.
        #
        # This stack reads another stack's outputs through
        # data.terraform_remote_state. Refreshing that data source requires the
        # upstream state OBJECT to exist -- and once the upstream stack has been
        # destroyed its state is empty, so no object is written at all and the
        # read fails hard with
        #
        #   Error: Unable to find remote state
        #   No stored state was found for the given workspace in the given backend.
        #
        # A destroy does not need those outputs: everything being destroyed is
        # already described by THIS stack's state, and the data source's last
        # value is cached there. Refreshing only adds a way for teardown to fail.
        #
        # Hit for real on 2026-08-23, when the network stack was destroyed before
        # this one and the teardown could not proceed without it.
        ${global.provisioner} destroy -refresh=false -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-sweep-orphaned-disks"
    description = "Delete PD disks the in-cluster reclaim could not finish; runs after the cluster is gone"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        # The backstop k8s-reclaim-csi-volumes.sh has always CLAIMED to have.
        #
        # That script reclaims PVs while the cluster still exists -- the only
        # moment the CSI controller can -- and when it runs out of time it warns
        # and exits 0, saying a cloud-side sweep would catch the rest. No such
        # sweep existed, and "the next destroy run" cannot help either: a later
        # run is a different cluster whose PVs do not reference these disks.
        #
        # So the leak was real and repeating: 3 disks on the 2026-08-27 teardown,
        # 8 (43 GB) on 2026-08-28.
        #
        # AFTER stage1-destroy-cluster deliberately. Before it, a disk still
        # attached to a draining node is not yet unattached and would be skipped;
        # after it, everything that leaked is unattached and visible.
        #
        # Never fails the teardown -- see the script's closing comment.
        bash "${terramate.root.path.fs.absolute}/scripts/gcp-sweep-orphaned-disks.sh" \
          --project "$(cd "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/init" && \
            awk -F'=' '/^[[:space:]]*project_id/{gsub(/[[:space:]"]/,"",$2); print $2}' variables.tfvars)" \
          --apply
      BASH
      ],
    ]
  }

  job {
    name        = "stage2-reconcile-state"
    description = "Drop any stage-2 state left behind, now that the cluster holding it is gone"
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/destroy-stage2.sh" \
          reconcile "${terramate.root.path.fs.absolute}/opentofu/gcp/gke/configure"
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

script "drift" "detect" {
  name        = "GCP Drift Check (opt-in)"
  description = "Detect drift in this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} plan -out=drift.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

# The global version of this script runs `tofu apply -auto-approve`. Ungated, a
# drift reconcile from opentofu/ would BUILD this GCP stack without anyone
# opting in -- which is the whole reason the missing overrides were a problem
# rather than an inconsistency.
script "drift" "reconcile" {
  name        = "GCP Drift Reconciliation (opt-in)"
  description = "Reconcile drift in this GCP stack when TM_CLOUD selects gcp"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        ${global.provisioner} apply -input=false -auto-approve -lock-timeout=5m -var-file=variables.tfvars drift.tfplan
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
