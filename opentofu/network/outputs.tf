output "vpc_id" {
  description = "The ID of the VPC"
  value       = module.vpc.vpc_id
}

output "public_subnets" {
  description = "List of IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnets" {
  description = "List of IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "intra_subnets" {
  description = "List of IDs of intra subnets"
  value       = module.vpc.intra_subnets
}

output "tailscale_security_group_id" {
  description = "value"
  value       = module.tailscale_subnet_router.security_group_id
}

output "pod_subnet_ids" {
  description = "List of pod subnet IDs (secondary CIDR for Cilium ENI)"
  value       = aws_subnet.pods[*].id
}

output "pod_cidr_block" {
  description = "Secondary CIDR block for pods"
  value       = var.pod_cidr
}
