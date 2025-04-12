script "destroy" {
  description = "Destroy the EKS cluster"
  job {
    name        = "eks-destroy"
    description = "Destroy the EKS cluster"
    commands = [
      [
        "bash",
        "../../scripts/eks-prepare-destroy.sh",
        "--cluster-name",
        global.eks_cluster_name,
        "--region",
        global.region,
        "--profile",
        global.profile,
      ],
      [
        global.provisioner, "destroy", "-var-file=variables.tfvars"
      ]
    ]
  }
}
