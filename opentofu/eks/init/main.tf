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

  # Bootstrap addons: VPC CNI + kube-proxy make nodes Ready
  # Stage 2 (opentofu/eks/configure/) replaces them with Cilium
  addons = {
    # VPC CNI: makes nodes Ready quickly (replaced by Cilium in stage 2)
    # WARM_ENI_TARGET=0 prevents VPC-CNI from creating secondary ENIs.
    # Without this, VPC-CNI pre-warms ENIs in 10.0.x.x subnets, and Cilium
    # reuses them instead of creating new ENIs in the 100.64.x.x pod subnets.
    vpc-cni = {
      before_compute = true
      most_recent    = true
      configuration_values = jsonencode({
        env = {
          WARM_ENI_TARGET = "0"
          WARM_IP_TARGET  = "1"
        }
      })
    }
    # kube-proxy: provides ClusterIP routing until Cilium takes over (deleted in stage 2)
    kube-proxy = {
      before_compute = true
      most_recent    = true
    }
    # Pod Identity Agent: uses hostNetwork, talks to AWS directly (always needed)
    eks-pod-identity-agent = {
      before_compute = true
      most_recent    = true
    }
    # CoreDNS: can reach Kubernetes API via ClusterIP
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        autoScaling = {
          enabled     = true
          minReplicas = 2
          maxReplicas = 4
        }
        tolerations = [{
          operator = "Exists"
        }]
      })
    }
    # EBS CSI Driver: can resolve AWS hostnames via CoreDNS
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = module.identity_ebs_csi_driver.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }
  # Stage 2 (opentofu/eks/configure/): Disable VPC CNI + kube-proxy → Install Cilium → Flux

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
    # Allow all traffic from pod CIDR (secondary CIDR 100.64.0.0/16)
    # Required for Cilium ENI mode with prefix delegation
    ingress_pod_cidr = {
      description = "Allow traffic from pod CIDR for pod-to-pod communication"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      cidr_blocks = ["100.64.0.0/16"]
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

      # Attach EKS cluster primary security group for communication with Karpenter nodes
      attach_cluster_primary_security_group = true

      iam_role_additional_policies = merge(
        { cilium_eni = aws_iam_policy.cilium_eni.arn },
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
