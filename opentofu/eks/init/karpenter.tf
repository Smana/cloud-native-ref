#trivy:ignore:AVD-AWS-0342
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Disable name prefix to have a predictable role name (Karpenter-<cluster_name>)
  # This allows hardcoding the role name in EC2NodeClass manifests
  node_iam_role_use_name_prefix = false

  node_iam_role_additional_policies = merge(
    var.enable_ssm ? { ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" } : {},
    var.iam_role_additional_policies
  )

  tags = var.tags
}

resource "aws_eks_pod_identity_association" "karpenter" {
  cluster_name    = module.eks.cluster_name
  namespace       = "karpenter"
  service_account = "karpenter"
  role_arn        = module.karpenter.iam_role_arn
}
