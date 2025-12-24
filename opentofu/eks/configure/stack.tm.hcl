stack {
  name        = "EKS Cluster - Configure"
  description = "Cilium CNI and Flux GitOps (Stage 2)"
  id          = "eks-configure"

  after = ["/opentofu/eks/init"]

  tags = [
    "aws",
    "eks",
    "kubernetes",
    "infrastructure"
  ]
}
