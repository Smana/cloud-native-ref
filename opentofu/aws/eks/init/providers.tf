provider "aws" {
  region = var.region
}

provider "aws" {
  region = "us-east-1"
  alias  = "virginia"
}

# No kubectl/kubernetes provider here on purpose: this stage only creates the
# EKS cluster. A provider configured from module.eks.* outputs would depend on
# resources created in this same apply, which alekc/kubectl cannot defer
# (fails with "no configuration has been provided"). Cluster-internal resources
# live in eks/configure, which runs against the already-created cluster.
