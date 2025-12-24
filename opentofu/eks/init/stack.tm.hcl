stack {
  name        = "EKS Cluster - Init"
  description = "EKS cluster infrastructure, bootstrap addons, IAM, secrets"
  id          = "eks-init"

  after = [
    "/opentofu/network",
    "/opentofu/openbao/management"
  ]

  tags = [
    "aws",
    "eks",
    "kubernetes",
    "infrastructure"
  ]
}
