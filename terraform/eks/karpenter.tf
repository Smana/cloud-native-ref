module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

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

resource "kubectl_manifest" "karpenter" {
  for_each = {
    for file_name in flatten([
      data.kubectl_filename_list.karpenter_default.matches,
      data.kubectl_filename_list.karpenter_io.matches
    ]) : file_name => file_name
  }

  yaml_body = templatefile(
    each.key,
    {
      cluster_name                   = module.eks.cluster_name,
      env                            = var.env,
      karpenter_node_iam_role_name   = module.karpenter.node_iam_role_name
      default_nodepool_cpu_limits    = var.karpenter_limits.default.cpu
      default_nodepool_memory_limits = var.karpenter_limits.default.memory
      io_nodepool_cpu_limits         = var.karpenter_limits.io.cpu
      io_nodepool_memory_limits      = var.karpenter_limits.io.memory
    }
  )

  depends_on = [
    helm_release.karpenter
  ]
}
