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
      # The configure stack's vault provider needs the CA chain on disk before
      # `tofu init`. Same step the management stack runs; configure/.tls/ is
      # gitignored.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c", "cd ../configure && bash '${terramate.root.path.fs.absolute}/scripts/openbao-config.sh' ca --root-ca-secret-name '${global.ca_chain_secret_name}' --ca-output-file .tls/ca.pem --region '${global.region}' --profile '${global.profile}'"],
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
      # The configure stack's vault provider needs the CA chain on disk before
      # `tofu init`. Same step the management stack runs; configure/.tls/ is
      # gitignored. In a `--reverse destroy`, OpenBao is still up at this point
      # (the OpenBao stacks come later in the reverse walk) -- without the CA,
      # `tofu destroy` here would abort at provider configuration, and while
      # `destroy-stage2.sh attempt` tolerates that failure, a clean teardown is
      # better than a tolerated one.
      #
      # BEST-EFFORT, and only on this path. The deploy and preview scripts above
      # keep their CA fetch strict, because there the vault provider has to
      # configure for the apply to mean anything. Here it is the opposite:
      # `write_ca` in openbao-config.sh exits non-zero on four paths -- secret
      # unreadable, empty value, mkdir failure, non-PEM content -- and a rotated
      # or already-deleted ca-chain secret reaches the first of them. Terramate
      # stops a script at the first failed command, so an unguarded fetch would
      # abort the run BEFORE stage1-destroy-cluster, stage3-sweep-orphaned-volumes
      # and stage4-reconcile-state, leaving a live EKS cluster and its nodes
      # billing with no workflow path left to remove them -- the one outcome this
      # job's description promises never to cause.
      #
      # Nothing downstream requires the CA: `destroy-stage2.sh attempt` already
      # tolerates a provider-configure failure, so a missing CA degrades this run
      # from "removed the in-cluster objects" to "left them for stage 1 to delete
      # with the cluster" -- the same outcome either way, moments later. The GCP
      # twin guards the identical call for the identical reason
      # (opentofu/gcp/gke/configure/workflows.tm.hcl), and
      # opentofu/aws/openbao/cluster/workflows.tm.hcl records the first time a CA
      # fetch hard-blocked a destroy here.
      #
      # The `cd` is inside the guard so that neither half can abort the script.
      ["bash", "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh", "--tm-run", "bash", "-c",
      "if ! (cd ../configure && bash '${terramate.root.path.fs.absolute}/scripts/openbao-config.sh' ca --root-ca-secret-name '${global.ca_chain_secret_name}' --ca-output-file .tls/ca.pem --region '${global.region}' --profile '${global.profile}'); then echo '[warn] CA chain fetch failed -- continuing anyway.'; echo '       The vault provider will fail to configure and destroy-stage2.sh will'; echo '       fall through to its tolerant path. Failing here instead would strand'; echo '       the live EKS cluster stage 1 is about to delete.'; fi"],
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
