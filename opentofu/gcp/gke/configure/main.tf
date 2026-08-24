# GKE Configure — Stage 2
#
# Dependency chain: gateway_api_crds -> cilium -> flux_operator -> flux_instance
#
# Simpler than the EKS equivalent: there is no VPC-CNI DaemonSet to disable first.
# Cilium's cni.exclusive displaces GKE's CNI config directly (verified by the
# Phase 1 gate: /etc/cni/net.d ends up holding only 05-cilium.conflist, with GKE's
# renamed .cilium_bak), and kubeProxyReplacement handles kube-proxy without
# patching GKE's managed DaemonSet -- which the addon manager would revert anyway.
#
# Kept local-exec-free like its EKS counterpart; imperative steps belong in
# Terramate jobs.

resource "helm_release" "cilium" {
  depends_on = [
    module.gateway_api_crds, # Gateway API CRDs must exist before Cilium starts
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
      value = local.cluster_endpoint
    },
    {
      name  = "k8sServicePort"
      value = "443"
    },
    {
      # MANDATORY under routingMode=native + ipam.mode=kubernetes. AWS ENI mode
      # derives this; GKE cannot, and the agent exits 255 without it:
      #   invalid daemon configuration: native routing cidr must be configured
      #   with option --ipv4-native-routing-cidr
      # Found by the Phase 1 gate. Sourced from state so it cannot drift from the
      # subnet's actual pod secondary range.
      name  = "ipv4NativeRoutingCIDR"
      value = local.pod_cidr
    },
  ]

  # wait = false deliberately, matching AWS: the agent cannot become Ready until
  # it owns the CNI, and blocking here would deadlock against nodes that are still
  # carrying the node.cilium.io/agent-not-ready taint.
  wait    = false
  timeout = 600
}

resource "helm_release" "flux_operator" {
  depends_on = [
    helm_release.cilium,
    kubectl_manifest.flux_system_namespace,
  ]

  name             = "flux-operator"
  repository       = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart            = "flux-operator"
  version          = var.flux_operator_version
  namespace        = "flux-system"
  create_namespace = false

  wait    = true
  timeout = 300

  # Purge the release if the install fails rather than leaving a `failed` revision
  # behind. OpenTofu does not record a failed create in state, so the orphan makes
  # every later apply fail with "cannot re-use a name that is still in use" -- hit
  # on AWS on 2026-08-19. `atomic` covers a failed install, `cleanup_on_fail` a
  # failed upgrade. `atomic` forces wait=true, which this release already sets --
  # do NOT copy it to helm_release.cilium, which sets wait=false on purpose.
  atomic          = true
  cleanup_on_fail = true
}

resource "helm_release" "flux_instance" {
  depends_on = [
    helm_release.flux_operator,
    kubectl_manifest.flux_system_secret,
  ]

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
      # A SIBLING tree to clusters/mycluster-0, not a shared one. The GCP cluster
      # runs a different component set -- no aws-load-balancer-controller, no
      # aws-efs-csi-driver, no Karpenter, no runtimeclass-nvidia.
      #
      # cluster_name already carries the gcp- prefix ("gcp-mycluster-0"), so this
      # must NOT add another one.
      name  = "instance.sync.path"
      value = "clusters/${var.cluster_name}"
    },
  ]

  wait    = true
  timeout = 600

  # Same orphan-release protection as helm_release.flux_operator above, and as
  # BOTH AWS releases carry. This was missing here purely because the resource was
  # copy-pasted from AWS before that fix was read across -- exactly the drift that
  # duplicating a bootstrap across two clouds produces.
  #
  # Without it a failed install leaves a `failed` revision that OpenTofu does not
  # record in state, so every later apply fails with "cannot re-use a name that is
  # still in use" until the release is uninstalled by hand.
  atomic          = true
  cleanup_on_fail = true
}
