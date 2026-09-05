locals {
  # This cluster's default block-storage class, defined once here so Flux's own
  # artifact PVC and every postBuild-substituted workload PVC cannot disagree.
  # Unlike GKE, this repo creates the StorageClass itself (kubernetes.tf) -- the
  # EBS CSI managed add-on supplies only the provisioner.
  storage_class = "gp3"

  github_app_secret = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)

  oidc_issuer_url  = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_issuer_host = replace(local.oidc_issuer_url, "https://", "")

  # Karpenter SQS queue name. The terraform-aws-modules karpenter submodule
  # defaults to "Karpenter-<cluster_name>" (coalesce(var.queue_name, ...)) and
  # eks/init does not override queue_name, so this matches the created queue.
  karpenter_queue_name = "Karpenter-${var.cluster_name}"
}
