locals {
  # This cluster's default block-storage class, defined ONCE and consumed three
  # times: the StorageClass object below (this repo creates gp3 itself -- the
  # EBS CSI managed add-on supplies only the provisioner), Flux's own artifact
  # PVC via the shared flux-instance template, and the storage_class key in the
  # Flux vars ConfigMap that postBuild substitutes into workload PVCs.
  storage_class = "gp3"

  cert_manager_approle = jsondecode(data.aws_secretsmanager_secret_version.cert_manager_approle.secret_string)
  github_app_secret    = jsondecode(data.aws_secretsmanager_secret_version.github_app.secret_string)

  oidc_issuer_url  = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  oidc_issuer_host = replace(local.oidc_issuer_url, "https://", "")

  # Karpenter SQS queue name. The terraform-aws-modules karpenter submodule
  # defaults to "Karpenter-<cluster_name>" (coalesce(var.queue_name, ...)) and
  # eks/init does not override queue_name, so this matches the created queue.
  karpenter_queue_name = "Karpenter-${var.cluster_name}"
}
