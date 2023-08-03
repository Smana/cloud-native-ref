# EKS post install kubernetes job with these changes
# * Configure storageclasses (deplace default gp2 volumes with gp3)

resource "kubernetes_service_account" "eks_init" {
  metadata {
    name      = "eks-init"
    namespace = "kube-system"
    labels = {
      owner = "vibe"
    }
  }
  depends_on = [
    module.eks
  ]
}

resource "kubernetes_cluster_role" "eks_init" {
  metadata {
    name = "eks-init"
  }
  rule {
    api_groups     = ["*"]
    resources      = ["daemonsets"]
    resource_names = ["aws-node"]
    verbs          = ["get", "list", "watch", "delete"]
  }

  depends_on = [
    module.eks
  ]
}

resource "kubernetes_cluster_role_binding" "eks_init" {
  metadata {
    name = "eks-init"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "eks-init"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "eks-init"
    namespace = "kube-system"
  }

  depends_on = [
    module.eks
  ]
}

resource "kubernetes_job" "delete_aws_cni_ds" {
  metadata {
    name      = "delete-aws-cni"
    namespace = "kube-system"
  }
  spec {
    template {
      metadata {}
      spec {
        service_account_name = "eks-init"
        container {
          name  = "kubectl"
          image = "bitnami/kubectl:1.22.6"
          args  = ["delete", "--ignore-not-found=true", "daemonsets", "aws-node", "-n", "kube-system"]
        }
        restart_policy = "Never"
        toleration {
          key    = "node.cilium.io/agent-not-ready"
          effect = "NoExecute"
          value  = true
        }
      }
    }
    backoff_limit = 4
  }
  wait_for_completion = true

  timeouts {
    create = "5m"
    update = "2m"
  }

  depends_on = [
    module.eks
  ]
}
