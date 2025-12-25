# EKS-specific Terramate scripts
# Two-stage deployment:
# Stage 1 (this stack): EKS cluster, bootstrap addons (VPC CNI, kube-proxy, CoreDNS, EBS CSI), IAM, secrets
# Stage 2 (configure stack): Disable VPC CNI + kube-proxy -> Install Cilium -> Flux
#
# Usage:
#   cd opentofu/eks/init
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
      ["bash", "-c", "cd ../configure && ${global.provisioner} init"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' $${TF_VAR_flux_git_ref:+-var=\"flux_git_ref=$${TF_VAR_flux_git_ref}\"}"],
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
      [
        "bash",
        "../../../scripts/eks-prepare-destroy.sh",
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
      ["bash", "-c", "cd ../configure && ${global.provisioner} init"],
      ["bash", "-c", "cd ../configure && ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars"],
    ]
  }

  job {
    name        = "stage1-destroy-cluster"
    description = "Destroy EKS cluster and infrastructure"
    commands = [
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
