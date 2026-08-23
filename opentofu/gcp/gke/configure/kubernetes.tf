# Cluster-specific values for Flux postBuild substitution.
#
# This is how cluster-specific config reaches shared manifests: anything under
# infrastructure/, security/ or observability/ that writes `${cluster_name}`,
# `${region}`, `${private_domain_name}` and friends is rendered per cluster from
# this ConfigMap, via `postBuild.substituteFrom` on the consuming Kustomization.
#
# The CLOUD-NEUTRAL keys below deliberately match the names the AWS ConfigMap
# (eks-<cluster>-vars) uses -- cluster_name, cluster_endpoint, region,
# environment, private_domain_name. That is what lets one manifest under
# infrastructure/base/ render correctly on either cloud. Renaming them here would
# silently break shared manifests on GCP only.
#
# AWS-only keys are deliberately absent (aws_account_id, oidc_provider_arn,
# vpc_id, karpenter_queue_name, route53_public_zone_id). The manifests that use
# them are AWS-specific and are excluded from clusters/gcp-mycluster-0. If a
# shared manifest ever needs one, the right fix is a cloud-neutral name provided
# by both ConfigMaps, not an AWS name faked on GCP.
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "gke-${var.cluster_name}-vars"
      namespace = "flux-system"
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
    data = {
      # Cloud-neutral — names shared with the AWS ConfigMap.
      cluster_name        = var.cluster_name
      cluster_endpoint    = local.cluster_endpoint
      environment         = var.env
      region              = var.region
      private_domain_name = local.init.private_domain_name

      # GCP-specific.
      project_id     = var.project_id
      project_number = local.init.project_number
      zone           = local.init.cluster_location
      workload_pool  = local.init.workload_pool
      network_name   = local.init.network_name
      node_cidr      = local.init.node_cidr
      pod_cidr       = local.pod_cidr
      service_cidr   = local.init.service_cidr
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

resource "kubectl_manifest" "flux_system_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "flux-system"
    }
  })
  server_side_apply = true
}

# Flux's Git credentials. Sourced from GCP Secret Manager (see data.tf) so the GCP
# bootstrap has no AWS dependency.
resource "kubectl_manifest" "flux_system_secret" {
  depends_on = [kubectl_manifest.flux_system_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "flux-system"
      namespace = "flux-system"
    }
    type = "Opaque"
    data = {
      for key, value in local.github_app_secret :
      key => base64encode(value)
    }
  })
  server_side_apply = true

  # The GitHub App private key is rendered into yaml_body, so without this it
  # appears unredacted in every plan diff and in the GCS state object.
  #
  # data.tf's comment says the secret is "deliberately NOT in OpenTofu" -- that is
  # true of its CREATION (we do not manage the Secret Manager entry) but NOT of
  # its value, which flows through this resource. Marking the field is what makes
  # the two statements consistent.
  sensitive_fields = ["data"]
}
