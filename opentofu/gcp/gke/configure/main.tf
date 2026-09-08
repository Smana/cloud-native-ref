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


# Is flux-operator already installed? See the lifecycle comment on the resource
# below, and scripts/helm-release-present.sh, for why terraform stops tracking
# this release and why that makes the check necessary.
#
# Never fails: an unreachable cluster answers "false", terraform attempts the
# create, and helm reports any genuine conflict itself.
data "external" "flux_operator_release" {
  program = ["bash", "${path.module}/../../../../scripts/helm-release-present.sh"]

  query = {
    name      = "flux-operator"
    namespace = "flux-system"
  }
}

resource "helm_release" "flux_operator" {
  # Bootstrap only. Zero when Flux already has the release -- which is every
  # deploy after the first, because the workflow drops it from state once the
  # FluxInstance is Ready. This can never destroy the operator: terraform has
  # already forgotten it, so count=0 has nothing in state to remove.
  count = data.external.flux_operator_release.result.present == "true" ? 0 : 1

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

  # Terraform BOOTSTRAPS this release; Flux owns it from the first reconcile.
  #
  # flux/operator/helmrelease.yaml re-manages the same Helm release, adding the
  # Web UI and its OIDC configuration -- none of which is declared here. Without
  # this, every apply reads Flux's values as drift and tries to revert them, and
  # an apply that lands mid-upgrade fails with "release: already exists" (hit on
  # 2026-09-08: revisions 23-27 inside 25 minutes).
  #
  # The version is Flux's too. `var.flux_operator_version` is the bootstrap
  # version only; flux/sources/ocirepo-flux-operator.yaml floats
  # `>=0.43.0 <1.0.0`, so bumping the global will NOT move a running cluster --
  # and without this block it would try to downgrade one.
  lifecycle {
    ignore_changes = all
  }

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

  values = [templatefile("${path.module}/../../../shared/helm_values/flux-instance.yaml.tftpl", {
    storage_class = local.storage_class
  })]

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
      # A SIBLING tree to clusters/aws-0, not a shared one. The GCP cluster
      # runs a different component set -- no aws-load-balancer-controller, no
      # aws-efs-csi-driver, no Karpenter, no runtimeclass-nvidia.
      #
      # cluster_name already carries the gcp- prefix ("gcp-0"), so this
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
