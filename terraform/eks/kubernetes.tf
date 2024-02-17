# Install Gateway API CRD's. Requirement to be installed before Cilium is running
resource "kubectl_manifest" "gateway_api_crds" {
  count      = length(local.gateway_api_crds_urls)
  yaml_body  = data.http.gateway_api_crds[count.index].body
  depends_on = [module.eks]
}

# EKS post install kubernetes job with these changes
resource "kubernetes_service_account" "eks_init" {
  metadata {
    name      = "eks-init"
    namespace = "kube-system"
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
          image = "bitnami/kubectl:1.29.2"
          args  = ["delete", "--ignore-not-found=true", "daemonsets", "aws-node", "-n", "kube-system"]
        }
        restart_policy = "Never"
        toleration {
          key    = "node.cilium.io/agent-not-ready"
          effect = "NoExecute"
          value  = true
        }
        toleration {
          operator = "Exists"
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


# Set the GP3 storageclass as default
resource "kubernetes_annotations" "gp2" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = "true"

  metadata {
    name = "gp2"
  }

  annotations = {
    # Modify annotations to remove gp2 as default storage class still retain the class
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [
    helm_release.aws_ebs_csi_driver
  ]
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      # Annotation to set gp3 as default storage class
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    encrypted = true
    fsType    = "ext4"
    type      = "gp3"
  }

  depends_on = [
    helm_release.aws_ebs_csi_driver
  ]
}
