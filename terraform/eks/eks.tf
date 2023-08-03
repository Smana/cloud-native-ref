# Demo cluster we need to access to the API publicly
#tfsec:ignore:aws-eks-no-public-cluster-access
#tfsec:ignore:aws-eks-no-public-cluster-access-to-cidr
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15"

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = true

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = {
        tolerations = [
          {
            operator = "Exists"
          }
        ]
      }
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  manage_aws_auth_configmap = true
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:user/smana"
      username = "smana"
      groups   = ["system:masters"]
    },
  ]

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    main = {
      name        = "main"
      description = "EKS managed node group used to bootstrap Karpenter"
      # Use a single subnet for costs reasons
      subnet_ids = [element(module.vpc.private_subnets, 0)]

      min_size     = 1
      max_size     = 3
      desired_size = 1

      # Bottlerocket
      use_custom_launch_template = false
      ami_type                   = "BOTTLEROCKET_x86_64"
      platform                   = "bottlerocket"

      capacity_type        = "SPOT"
      force_update_version = true
      instance_types       = ["c6i.xlarge", "c5.xlarge"]
      taints = [
        {
          key    = "node.cilium.io/agent-not-ready"
          value  = "true"
          effect = "NO_EXECUTE"
        }
      ]
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }

  // For the load balancer to work refer to https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/docs/faq.md
  node_security_group_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = null
  }
}
