data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Reference the existing model-weights S3 bucket created by the Crossplane
# `xinferenceservices` composition (Phase 4a). Versioning is required by S3
# Files; the composition already enables it.
data "aws_s3_bucket" "models" {
  bucket = var.models_bucket_name
}

# VPC + subnet discovery from the network stack outputs. Mount targets must
# live in subnets routable from EKS worker nodes (the 10.0.x.x private set,
# not the 100.64.x.x pod set used by Cilium ENIs).
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "demo-smana-remote-backend"
    key    = "cloud-native-ref/network/opentofu.tfstate"
    region = var.region
  }
}

# Worker-node security group — discovered by the cluster tag the
# terraform-aws-modules/eks module applies. Avoids coupling to eks/init's
# outputs (which currently exposes none).
data "aws_security_group" "eks_nodes" {
  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-node"]
  }
  filter {
    name   = "vpc-id"
    values = [data.terraform_remote_state.network.outputs.vpc_id]
  }
}
