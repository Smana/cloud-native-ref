#trivy:ignore:AVD-AWS-0104 # Allow unrestricted egress traffic
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21"

  name                   = var.name
  kubernetes_version     = var.kubernetes_version
  endpoint_public_access = false

  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  addons = {
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

  identity_providers = var.identity_providers

  vpc_id                   = data.aws_vpc.selected.id
  subnet_ids               = data.aws_subnets.private.ids
  control_plane_subnet_ids = data.aws_subnets.intra.ids

  security_group_additional_rules = {
    ingress_source_security_group_id = {
      description              = "Ingress from the Tailscale security group to the API server"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = data.aws_security_group.tailscale.id
    }
  }

  # Allow control plane to reach node/pod ports for API server service proxy feature
  node_security_group_additional_rules = {
    ingress_cluster_to_node_all_ports = {
      description                   = "Cluster API to node groups (for API server service proxy)"
      protocol                      = "tcp"
      from_port                     = 1025
      to_port                       = 65535
      type                          = "ingress"
      source_cluster_security_group = true
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

      ami_type            = "BOTTLEROCKET_x86_64"
      ami_release_version = "1.49.0-713f44ce"

      metadata_options = {
        http_endpoint = "enabled"
        http_tokens   = "required"
      }

      iam_role_additional_policies = merge(
        var.enable_ssm ? { ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" } : {},
        var.iam_role_additional_policies
      )

      capacity_type        = "SPOT"
      force_update_version = true
      instance_types       = ["c7i.xlarge", "c7i-flex.xlarge", "c6i.xlarge", "t3a.xlarge", "c7i.2xlarge", "c7i-flex.2xlarge"]
      # Exemple of how to configure Bottlerocket. https://bottlerocket.dev/en/os/1.41.x/api/settings/
      # bootstrap_extra_args = <<-EOT
      #   [settings.host-containers.admin]
      #   enabled = true
      # EOT
      taints = {
        "cilium" = {
          key    = "node.cilium.io/agent-not-ready"
          value  = "true"
          effect = "NO_EXECUTE"
        }
      }
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.name
  }

  // For the load balancer to work refer to https://github.com/opentofu-aws-modules/opentofu-aws-eks/blob/master/docs/faq.md
  node_security_group_tags = {
    "kubernetes.io/cluster/${var.name}" = null
  }
}
