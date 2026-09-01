#trivy:ignore:AVD-AWS-0104 # Allow unrestricted egress traffic
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21"

  name                   = var.name
  kubernetes_version     = var.kubernetes_version
  endpoint_public_access = false

  # No control-plane logging to CloudWatch, deliberately.
  #
  # This was all five types, and it cost $144/month -- 20% of the entire AWS
  # bill and its single largest line, every cent of it EUW3-VendedLog-Bytes
  # dominated by the audit log. Nothing in this repository reads any of it:
  # observability is VictoriaMetrics/VictoriaLogs, and the platform uses no
  # cloud-provider monitoring on either cloud (see website/content/docs/
  # platform/observability).
  #
  # So it was $144/month of logs nobody could look at without first going to
  # find them in a console.
  #
  # Turn types back on deliberately if you need them -- `audit` is the one worth
  # having during a security investigation, and it is also the expensive one.
  # The module's own default is ["audit", "api", "authenticator"].
  enabled_log_types = []

  # Bootstrap addons: VPC CNI + kube-proxy make nodes Ready
  # Stage 2 (opentofu/aws/eks/configure/) replaces them with Cilium
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
  # Stage 2 (opentofu/aws/eks/configure/): Disable VPC CNI + kube-proxy → Install Cilium → Flux

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
      name = "main"
      # Use a single subnet for costs reasons
      subnet_ids = [element(data.aws_subnets.private.ids, 0)]

      min_size     = 2
      max_size     = 3
      desired_size = 2

      ami_type            = "BOTTLEROCKET_x86_64"
      ami_release_version = "1.54.0-5043decc"

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
      # large-tier only, and the 8 GiB-RAM m/t families rather than 4 GiB
      # c-larges: these two nodes are the pre-Karpenter critical path (Cilium,
      # CoreDNS, Flux, Karpenter itself all land here during stage 2, before
      # any NodePool exists), and memory is what runs out first in that burst.
      # Everything else reschedules onto Karpenter capacity once it exists, so
      # steady-state the pair hosts very little — xlarge/2xlarge tiers made it
      # the single biggest line on the bill (~$180/mo) for idle headroom
      # Karpenter can never consolidate. Four families keep spot diversity.
      instance_types = ["m7i-flex.large", "t3a.large", "m8i.large", "m6i.large"]

      # max-pods must match what CILIUM can address, not what AWS can attach.
      #
      # The AMI default comes from the AWS formula, which counts the primary ENI's
      # secondary IPs:        ENIs x (IPs-1) + 2  =  4 x 14 + 2  =  58
      # Cilium runs ENI IPAM with first-interface-index: 1, so eth0 is skipped
      # entirely -- it sits in the NODE subnet (10.0.0.0/20) while pods must come
      # from the pod subnet (100.64.0.0/18). Its real ceiling is:
      #                       (ENIs-1) x (IPs-1)  =  3 x 14      =  42
      #
      # The 16-pod gap is not theoretical. The scheduler fills to 58, Cilium runs
      # out at 42, and the overflow sits in ContainerCreating on "no IPs currently
      # available on the node" -- observed on both nodes of this group.
      #
      # That 42 floor assumed prefix delegation could not be relied on here --
      # these nodes are created during bootstrap, before a cilium-operator exists
      # to apply it, and Cilium never converts an existing secondary-IP ENI. Both
      # showed prefixes=0 while every later Karpenter node had prefixes.
      #
      # That assumption no longer holds. The deploy script now recycles node-group
      # nodes after Cilium is healthy (scripts/eks-recycle-bootstrap-nodes.sh,
      # stage 3), so their replacements come up with Cilium already running and DO
      # get prefixes. Verified on aws-0: both node-group nodes now report
      # prefixes=3 after being replaced, alongside every Karpenter node.
      #
      # With prefix delegation applied the ceiling becomes
      #                       (ENIs-1) x (IPs-1) x 16  =  3 x 14 x 16  =  672
      # so IP addressability stops being the binding constraint and the limit
      # becomes Kubernetes' own recommended maximum of 110 pods per node.
      #
      # 110 accepts one residual risk deliberately: upstream reports
      # isPrefixDelegated flipping across an instance's lifetime
      # (cilium/cilium#29634). If that happened, capacity would fall back to 42
      # and pods above it would sit in ContainerCreating on "no IPs currently
      # available on the node". The 42 floor was immune to that; 110 is not. The
      # trade is deliberate -- pinning every node to 42 wastes ~85% of a
      # prefix-delegated node to guard against a bug we have not observed here.
      # If it ever bites, that symptom is the signature to look for.
      #
      # Re-check with `aws ec2 describe-instance-types` before adding a type.
      # Bottlerocket settings reference: https://bottlerocket.dev/en/os/1.41.x/api/settings/
      bootstrap_extra_args = <<-EOT
        [settings.kubernetes]
        max-pods = 110
      EOT
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
