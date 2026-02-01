# EKS Configure - Stage 2
# Dependency chain:
# disable_vpc_cni + cilium_cni_config -> cilium -> disable_kube_proxy -> flux_operator -> flux_instance
#
# Note: We PATCH the DaemonSets instead of deleting EKS addons to avoid local-exec.
# Cilium's unmanagedPodWatcher automatically restarts pods not managed by Cilium.

locals {
  api_endpoint = replace(data.aws_eks_cluster.this.endpoint, "https://", "")
}

# =============================================================================
# Step 1: Disable VPC CNI by patching DaemonSet nodeSelector
# =============================================================================
# Instead of deleting the EKS addon, we patch the aws-node DaemonSet to not
# schedule on any nodes. This is cleaner than local-exec and fully declarative.
resource "kubectl_manifest" "disable_vpc_cni" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "aws-node"
      namespace = "kube-system"
    }
    spec = {
      template = {
        spec = {
          nodeSelector = {
            "io.cilium/aws-node-enabled" = "true" # No nodes have this label
          }
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

# =============================================================================
# Step 2: Install Cilium CNI with kube-proxy replacement
# =============================================================================
# Cilium's operator.unmanagedPodWatcher automatically restarts pods not managed
# by Cilium, so we don't need a manual restart script.
resource "helm_release" "cilium" {
  depends_on = [
    kubectl_manifest.disable_vpc_cni,
    kubectl_manifest.cilium_cni_config,
  ]

  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false

  values = [file("${path.module}/../init/helm_values/cilium.yaml")]

  set = [
    {
      name  = "cluster.name"
      value = var.cluster_name
    },
    {
      name  = "k8sServiceHost"
      value = local.api_endpoint
    },
    {
      name  = "k8sServicePort"
      value = "443"
    },
    {
      name  = "eni.securityGroupTags.karpenter\\.sh/discovery"
      value = var.cluster_name
    },
    {
      name  = "eni.instanceTagsFilter[0]"
      value = "aws:eks:cluster-name=${var.cluster_name}"
    }
  ]

  wait    = true
  timeout = 600
}

# =============================================================================
# Step 3: Disable kube-proxy by patching DaemonSet nodeSelector
# =============================================================================
# Cilium with kubeProxyReplacement=true provides eBPF-based service routing,
# so kube-proxy is no longer needed.
resource "kubectl_manifest" "disable_kube_proxy" {
  depends_on = [helm_release.cilium]

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "DaemonSet"
    metadata = {
      name      = "kube-proxy"
      namespace = "kube-system"
    }
    spec = {
      template = {
        spec = {
          nodeSelector = {
            "io.cilium/kube-proxy-enabled" = "true" # No nodes have this label
          }
        }
      }
    }
  })
  server_side_apply = true
  force_conflicts   = true
}

# =============================================================================
# Step 4: Wait for core services to be ready
# =============================================================================
# Use kubectl_manifest to create a "check" that verifies deployments are ready.
# This is a workaround since we can't use local-exec.
# The helm_release for Flux depends on Cilium being ready (wait=true),
# so core services should be ready by the time we get here.

# =============================================================================
# Step 5: Install Flux Operator
# =============================================================================
resource "helm_release" "flux_operator" {
  depends_on = [kubectl_manifest.disable_kube_proxy]

  name             = "flux-operator"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.flux_operator_version
  namespace        = "flux-system"
  create_namespace = false # Created by Stage 1

  wait    = true
  timeout = 300
}

# =============================================================================
# Step 6: Install Flux Instance
# =============================================================================
resource "helm_release" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  name             = "flux"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-instance"
  version          = var.flux_instance_version
  namespace        = "flux-system"
  create_namespace = false

  values = [file("${path.module}/../init/helm_values/flux-instance.yaml")]

  set = [
    {
      name  = "instance.sync.url"
      value = var.flux_sync_url
    },
    {
      name  = "instance.sync.ref"
      value = var.flux_git_ref
    },
    {
      name  = "instance.sync.path"
      value = "clusters/${var.cluster_name}"
    }
  ]

  wait    = true
  timeout = 300
}
