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
      ["bash", "-c", "cd ../configure && ${global.provisioner} init -lock-timeout=5m"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var=\"flux_git_ref=$${TF_VAR_flux_git_ref}\"}"],
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
      ["bash", "-c", "${terramate.root.path.fs.absolute}/scripts/eks-recycle-bootstrap-nodes.sh --cluster-name ${global.eks_cluster_name} --region ${global.region}"],
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
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # Init before anything is torn down: a lock file predating a new provider
      # must fail here, not after Flux has been suspended. Same stack dir as the
      # stage1-destroy-cluster job below, so that job inherits this init.
      [global.provisioner, "init", "-lock-timeout=5m"],
      [
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

  job {
    name        = "stage2-destroy-addons"
    description = "Destroy Cilium and Flux (configure stack)"
    commands = [
      ["bash", "-c", "cd ../configure && ${global.provisioner} init -lock-timeout=5m"],
      # The three version variables carry no defaults (see configure/variables.tf),
      # so they must be supplied here too: OpenTofu requires every variable to be
      # set on destroy, not just on apply.
      ["bash", "-c", "cd ../configure && ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}'"],
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
}
