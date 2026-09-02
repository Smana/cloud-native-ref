# EKS-specific Terramate scripts
# Two-stage deployment:
# Stage 1 (this stack): EKS cluster, bootstrap addons (VPC CNI, kube-proxy, CoreDNS, EBS CSI), IAM, secrets
# Stage 2 (configure stack): Disable VPC CNI + kube-proxy -> Install Cilium -> Flux
#
# Usage:
#   cd opentofu/aws/eks/init
#   terramate script run deploy                                        # Full deployment (both stages)
#   TF_VAR_flux_git_ref='refs/heads/feature-branch' terramate script run deploy  # With custom ref
#   terramate script run deploy-stage1                                 # Stage 1 only (infrastructure)

script "deploy" {
  name        = "EKS Full Deployment"
  description = "Deploy EKS cluster (Stage 1) and Cilium + Flux (Stage 2)"

  job {
    name        = "stage1-infrastructure"
    description = "Deploy EKS cluster, bootstrap addons, IAM, secrets"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }

  job {
    name        = "stage2-cilium-and-flux"
    description = "Disable VPC CNI/kube-proxy, install Cilium and Flux"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c", "cd ../configure && ${global.provisioner} init -lock-timeout=5m"],
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c", "cd ../configure && ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var=\"flux_git_ref=$${TF_VAR_flux_git_ref}\"}"],
    ]
  }

  # Stage 3: the node group exists from Stage 1, i.e. BEFORE Cilium. Cilium
  # therefore creates its ENIs filled with individual secondary IPs instead of
  # /28 prefixes, and never converts them — leaving the bootstrap nodes with a
  # permanent ~42-IP ceiling while every Karpenter node gets ~240. Measured on
  # aws-0: two c7i-flex.xlarge MNG nodes at prefixes=0 next to a Karpenter
  # c7i-flex.xlarge at prefixes=2. Same instance type; the difference is that the
  # MNG nodes predate Cilium.
  #
  # It surfaces far from the cause: a DaemonSet pod that cannot get an IP keeps
  # its DaemonSet InProgress, so Helm's --wait times out and an unrelated
  # HelmRelease reports InstallFailed.
  #
  # The script is idempotent — it inspects each node's CiliumNode and only
  # recycles ones actually missing prefixes — so this is a no-op on every deploy
  # after the first, and on clusters where prefix delegation is off.
  #
  # This lives in a Terramate job rather than a tofu local-exec on purpose: the
  # configure stack is deliberately local-exec-free (see the comments in
  # configure/main.tf), and imperative steps belong here, as with
  # eks-prepare-destroy.sh on the destroy path.
  job {
    name        = "stage3-recycle-bootstrap-nodes"
    description = "Recycle node-group nodes whose ENIs predate Cilium (no-op once they use prefix delegation)"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c", "${terramate.root.path.fs.absolute}/scripts/eks-recycle-bootstrap-nodes.sh --cluster-name ${global.eks_cluster_name} --region ${global.region}"],
    ]
  }

  # Stage 4: OIDC clients, for this cluster AND for anything consuming it.
  #
  # WHY IT LIVES HERE, ON THE PRIMARY CLOUD
  #
  # A consuming cluster cannot register its own clients. `terramate list
  # --run-order` puts gcp/gke/init at position 6 and aws/eks/init at 11, so on a
  # TM_CLOUD=all run GCP is fully deployed five stacks before aws-0 exists --
  # there is no directory to register into and no admin PAT yet. Putting the step
  # in the consumer's own deploy (the first attempt) can only work when GCP is
  # added to an already-running AWS platform, which is not the normal case.
  #
  # The primary cloud has neither problem: by the time this runs its ZITADEL is
  # up and it holds the admin PAT. ADR-0027 already says the primary owns what
  # cannot exist twice; registering every cluster's clients is part of owning
  # the directory.
  #
  # aws-0's own clients are registered too, not only consumers'. They have so far
  # existed only because the database restore seed carries them -- a bootstrap
  # against an empty database would have none, and nothing would say so until
  # someone tried to log in.
  job {
    name        = "stage4-oidc-clients"
    description = "Register OIDC clients for this cluster and for any cluster consuming its identity provider"
    commands = [
      ["bash", "-c", <<-BASH
        set -euo pipefail
        ROOT="${terramate.root.path.fs.absolute}"

        if [ "${global.primary_cloud}" != "aws" ]; then
          echo "== skipping: primary_cloud is \"${global.primary_cloud}\", so this cluster does not host the directory"
          exit 0
        fi

        CONF="$${ROOT}/opentofu/aws/eks/configure/variables.tfvars"
        PUBLIC_DOMAIN="$(awk -F'=' '/^[[:space:]]*public_domain_name/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${CONF}")"
        PRIVATE_DOMAIN="$(awk -F'=' '/^[[:space:]]*private_domain_name/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${CONF}")"
        if [ -z "$${PUBLIC_DOMAIN}" ] || [ -z "$${PRIVATE_DOMAIN}" ]; then
          echo "[warn] could not read the domains from $${CONF}; skipping OIDC registration"
          exit 0
        fi
        IDP_URL="https://auth.$${PUBLIC_DOMAIN}"

        echo "== waiting for ZITADEL (up to 15m)"
        deadline=$$(( SECONDS + 900 ))
        while [ "$$SECONDS" -lt "$$deadline" ]; do
          if [ "$(kubectl get deploy zitadel -n security -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null; then
            break
          fi
          sleep 20
        done
        if [ "$(kubectl get deploy zitadel -n security -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" -lt 1 ] 2>/dev/null; then
          echo "[warn] ZITADEL not ready in 15m; skipping OIDC client registration."
          echo "       Re-run by hand once it is up -- see scripts/zitadel-oidc-clients.sh."
          exit 0
        fi

        echo "== registering ${global.eks_cluster_name}'s own OIDC clients"
        IDP_URL="$${IDP_URL}" PRIVATE_DOMAIN="$${PRIVATE_DOMAIN}" \
          bash "$${ROOT}/scripts/zitadel-oidc-clients.sh" sync \
            --cluster "${global.eks_cluster_name}" --cloud aws --region "${global.region}" --apply || \
          echo "[warn] registration for ${global.eks_cluster_name} failed; re-run it by hand"

        # Consuming clusters. TM_CLOUD is the right source for "which lanes is
        # this invocation deploying" -- that is exactly the question, and it
        # avoids a fourth place enumerating clouds. A GCP lane not being deployed
        # has no secret store to write into, so registering for it would fail
        # rather than help.
        case ",$${TM_CLOUD:-aws}," in
          *,gcp,*|*,all,*)
            # private_domain_name and project_id live in the NETWORK stack's
            # tfvars, not gke/configure's -- verified, and reading a key that is
            # not there yields an empty string and skips the registration behind
            # a warning nobody reads.
            GCP_NET="$${ROOT}/opentofu/gcp/network/variables.tfvars"
            GCP_PRIVATE="$(awk -F'=' '/^[[:space:]]*private_domain_name/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${GCP_NET}" 2>/dev/null || true)"
            GCP_PROJECT="$(awk -F'=' '/^[[:space:]]*project_id/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${GCP_NET}" 2>/dev/null || true)"
            GCP_CLUSTER="$(awk -F'=' '/^[[:space:]]*cluster_name/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${ROOT}/opentofu/gcp/gke/init/variables.tfvars" 2>/dev/null || true)"
            if [ -z "$${GCP_PRIVATE}" ] || [ -z "$${GCP_CLUSTER}" ] || [ -z "$${GCP_PROJECT}" ]; then
              echo "[warn] could not read the GCP cluster/domain/project; skipping its OIDC registration"
              exit 0
            fi
            echo "== registering $${GCP_CLUSTER}'s OIDC clients in this cluster's directory"
            # --idp-cloud aws: admin PAT from AWS, client secrets into GCP. That
            # split is what makes a consuming cluster expressible at all, and it
            # is what suffixes its app names so the two clusters do not contend
            # for one app.
            # --workforce-pool is a no-op in THIS topology -- with AWS primary the
            # pool's committed audience is already this directory's project id --
            # but passing it makes a drifted audience self-correct rather than
            # waiting for someone to notice an invalid_grant.
            WORKFORCE_POOL="$(awk -F'=' '/^[[:space:]]*workforce_pool_id/{gsub(/[[:space:]"]/,"",$$2); print $$2}' "$${ROOT}/opentofu/gcp/workforce-identity/variables.tfvars" 2>/dev/null || true)"
            IDP_URL="$${IDP_URL}" PRIVATE_DOMAIN="$${GCP_PRIVATE}" \
              bash "$${ROOT}/scripts/zitadel-oidc-clients.sh" sync \
                --cluster "$${GCP_CLUSTER}" \
                --cloud gcp --project "$${GCP_PROJECT}" \
                --workforce-pool "$${WORKFORCE_POOL}" \
                --idp-cloud aws --region "${global.region}" --apply || \
              echo "[warn] registration for $${GCP_CLUSTER} failed; re-run it by hand"
            ;;
        esac
      BASH
      ],
    ]
  }
}

script "deploy-stage1" {
  name        = "EKS Stage 1 Only - Cluster & Infrastructure"
  description = "Create EKS cluster with bootstrap CNI (without Cilium/Flux)"

  job {
    name        = "stage1-infrastructure"
    description = "Deploy EKS cluster, bootstrap addons, IAM, secrets"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}

script "preview" {
  name        = "EKS Deployment Preview"
  description = "Preview EKS deployment changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      ["trivy", "config", "--exit-code=1", "--ignorefile=./.trivyignore.yaml", "."],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "EKS Full Destroy"
  description = "Destroy EKS cluster: prepare -> destroy addons (Stage 2) -> destroy cluster (Stage 1)"

  job {
    name        = "prepare-destroy"
    description = "Suspend Flux and clean up Kubernetes resources (Gateways, NodePools, EPIs)"
    commands = [
      # Single y/n prompt; cached for 10 min so `--reverse destroy` asks once.
      # Bypass with TM_DESTROY_CONFIRMED=true for CI.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # Init before anything is torn down: a lock file predating a new provider
      # must fail here, not after Flux has been suspended. Same stack dir as the
      # stage1-destroy-cluster job below, so that job inherits this init.
      [global.provisioner, "init", "-lock-timeout=5m"],
      [
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/eks-prepare-destroy.sh",
        "--cluster-name",
        global.eks_cluster_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
    ]
  }

  # Attempts a graceful teardown and NEVER gates the cluster deletion. Everything
  # this stack manages lives inside the cluster stage 1 deletes moments later, so
  # a failure here costs nothing -- while treating it as fatal costs the one
  # billable resource, which is left running with no workflow path to remove it.
  #
  # Measured on 2026-08-29: a teardown reached this job with the cluster already
  # deleted, so every in-cluster delete returned `the server has asked for the
  # client to provide credentials` against an endpoint that no longer resolved in
  # DNS. Errors about objects that had ceased to exist, failing the run. GKE hit
  # the same wall on 2026-08-23 from the other direction (an access token that
  # expired mid-destroy) and grew this helper; AWS kept the bare `tofu destroy`
  # until it bit here too.
  #
  # The version variables carry no defaults (see configure/variables.tf), and
  # OpenTofu requires every variable to be set on destroy as well as on apply.
  job {
    name        = "stage2-destroy-addons"
    description = "Attempt a graceful Cilium and Flux teardown; never blocks the cluster deletion"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c",
        "bash '${terramate.root.path.fs.absolute}/scripts/destroy-stage2.sh' attempt '${terramate.root.path.fs.absolute}/opentofu/aws/eks/configure' -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'"],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy EKS cluster and infrastructure"
    commands = [
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }

  # A SECOND sweep, and the moment is the whole point.
  #
  # prepare-destroy already sweeps orphaned volumes, but it runs BEFORE the
  # destroy, moments after deleting the PVCs -- so it only catches what has
  # finished detaching by then. Its own warning admits the rest ("may still be
  # detaching -- the next run retries"), and the next run is a whole rebuild
  # away, so a volume that detached one second late bills until then. That is
  # how 62 volumes (~518 GiB) accumulated by 2026-07: each teardown leaving a
  # few for the next one to find.
  #
  # Here every node is already terminated, so every volume of this cluster is
  # unambiguously detached and there is no in-flight state to race. Same three
  # filters as the earlier sweep -- available + this cluster's tag + the CSI
  # driver's PVC tag -- so it cannot touch a live cluster or a hand-made volume.
  # The two things that make `tofu destroy` FAIL, cleared before it runs.
  #
  # Opposite ordering to the volume sweep below, and for the opposite reason: a
  # volume has to finish detaching first, so that sweep runs after. These two
  # BLOCK the destroy, so a sweep that ran afterwards would never be reached --
  # on 2026-09-02 the destroy failed here and terramate stopped, leaving the GCP
  # stacks entirely untouched and a GKE cluster running.
  #
  # Idempotent and dry-run-safe; on a healthy teardown it finds nothing and says
  # so. See scripts/aws-sweep-teardown-blockers.sh for what it will not touch.
  job {
    name        = "stage0-sweep-teardown-blockers"
    description = "Clear ExternalDNS records and the EKS-managed SG that block DeleteHostedZone / DeleteVpc"
    commands = [
      [
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/aws-sweep-teardown-blockers.sh",
        "--cluster-name",
        global.eks_cluster_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--apply",
      ],
    ]
  }

  job {
    name        = "stage3-sweep-orphaned-volumes"
    description = "Delete EBS volumes that were still detaching when the pre-destroy sweep ran"
    commands = [
      [
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
        "--tm-run",
        "bash",
        "${terramate.root.path.fs.absolute}/scripts/aws-sweep-orphaned-volumes.sh",
        "--cluster-name",
        global.eks_cluster_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
        "--apply",
      ],
    ]
  }

  # Runs LAST, and only here. Anything still in the configure stack's state
  # describes an object that lived in the cluster stage 1 has now provably
  # deleted, so it cannot exist any more and state should stop claiming it.
  #
  # Clearing state inside stage 2 would be wrong in the other direction: if the
  # cluster destroy then failed, state would have been emptied for resources that
  # are still there. Only after the cluster is confirmed gone is dropping them
  # safe both ways.
  job {
    name        = "stage4-reconcile-state"
    description = "Drop stage-2 state entries whose cluster no longer exists"
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c",
        "bash '${terramate.root.path.fs.absolute}/scripts/destroy-stage2.sh' reconcile '${terramate.root.path.fs.absolute}/opentofu/aws/eks/configure'"],
    ]
  }
}
