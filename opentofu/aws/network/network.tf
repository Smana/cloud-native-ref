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
      Name = "vpc-${var.region}-${var.env}-pods-${local.azs[count.index]}"
      # NOTE: Do NOT add "kubernetes.io/role/cni" tag here!
      # VPC-CNI uses that tag to discover subnets during EKS bootstrap (Stage 1).
      # This causes orphan ENIs when Cilium takes over in Stage 2.
      # Cilium uses subnetTagsFilter (kubernetes.io/role/internal-elb=1) instead.
      "cilium.io/pod-subnet" = "true" # For future use when Cilium bug #43493 is fixed
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

# S3 gateway endpoint: free, and it takes the bulk of NAT data processing out
# (#1941 — measured ~$41/month against $35/month of gateway-hours). Image
# pulls are the main driver, and ECR serves LAYER bytes from S3, so this one
# endpoint captures them along with CNPG backups and every other S3 flow from
# the private and pod subnets. DNS is unchanged (traffic is steered by the
# endpoint's prefix list in the route tables), so Cilium toFQDNs policies are
# unaffected.
#
# ECR *interface* endpoints (api/dkr) are deliberately NOT added: with layers
# riding S3 only the small auth/manifest calls remain on the NAT path, and two
# interface endpoints bill ~$16/month — more than they would save here.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(
    local.tags,
    { Name = "vpc-${var.region}-${var.env}-s3" }
  )
}
