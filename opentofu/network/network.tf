module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "vpc-${var.region}-${var.env}"
  cidr = var.vpc_cidr

  # Secondary CIDR for pod IPs (CG-NAT space)
  secondary_cidr_blocks = [var.pod_cidr]

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.env
  }

  tags = merge(
    local.tags,
    var.tags
  )
}

# Pod subnets in secondary CIDR (100.64.0.0/16)
# Using /18 subnets = 16,384 IPs per AZ for high pod density with prefix delegation
resource "aws_subnet" "pods" {
  count = length(local.azs)

  vpc_id                  = module.vpc.vpc_id
  cidr_block              = cidrsubnet(var.pod_cidr, 2, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(
    local.tags,
    {
      Name                     = "vpc-${var.region}-${var.env}-pods-${local.azs[count.index]}"
      "kubernetes.io/role/cni" = 1
      "cilium.io/pod-subnet"   = "true"
    }
  )

  depends_on = [module.vpc]
}

# Associate pod subnets with private route table for NAT access
resource "aws_route_table_association" "pods" {
  count = length(local.azs)

  subnet_id      = aws_subnet.pods[count.index].id
  route_table_id = module.vpc.private_route_table_ids[0]
}
