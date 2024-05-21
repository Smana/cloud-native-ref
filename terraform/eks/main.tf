# Demo cluster we need to access to the API publicly
#tfsec:ignore:aws-eks-no-public-cluster-access
#tfsec:ignore:aws-eks-no-public-cluster-access-to-cidr
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20"

  cluster_name                   = var.cluster_name
  cluster_version                = var.cluster_version
  cluster_endpoint_public_access = false

  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode(
        {
          "autoScaling" : {
            "enabled" : true,
            "minReplicas" : 2,
            "maxReplicas" : 4
          }
          tolerations = [
            {
              operator = "Exists"
            }
          ]
        }
      )
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  enable_cluster_creator_admin_permissions = true

  #access_entries = {
  # # No need to define this user as this is the one that creates the cluster and the variable 'enable_cluster_creator_admin_permissions' is set to true
  #  smana = {
  #    user_name         = "smana"
  #    principal_arn     = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:user/smana"
  #    kubernetes_groups = ["cluster-admin"]
  #  }
  #}

  vpc_id                   = data.aws_vpc.selected.id
  subnet_ids               = data.aws_subnets.private.ids
  control_plane_subnet_ids = data.aws_subnets.intra.ids

  cluster_security_group_additional_rules = {
    ingress_source_security_group_id = {
      description              = "Ingress from the Tailscale security group to the API server"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = data.aws_security_group.tailscale.id
    }
  }

  eks_managed_node_groups = {
    main = {
      name        = "main"
      description = "EKS managed node group used to bootstrap Karpenter"
      # Use a single subnet for costs reasons
      subnet_ids = [element(data.aws_subnets.private.ids, 0)]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      ami_type = "AL2023_x86_64_STANDARD"

      use_latest_ami_release_version = true

      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content      = <<-EOT
            ---
            apiVersion: node.eks.aws/v1alpha1
            kind: NodeConfig
            spec:
              kubelet:
                config:
                  shutdownGracePeriod: 30s
                  featureGates:
                    DisableKubeletCloudCredentialProviders: true
          EOT
        }
      ]

      capacity_type        = "SPOT"
      force_update_version = true
      instance_types       = ["c7i.xlarge", "c6i.xlarge", "c5.xlarge"]
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
