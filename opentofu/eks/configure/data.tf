data "aws_eks_cluster" "this" {
  name = var.cluster_name
}
