stack {
  name        = "EKS Cluster - Init"
  description = "EKS cluster infrastructure, bootstrap addons, IAM, secrets"
  id          = "eks-init"

  after = [
    "/opentofu/aws/network",
    "/opentofu/aws/openbao/management"
  ]

  tags = [
    "aws",
    "eks",
    "kubernetes",
    "infrastructure"
  ]
}
