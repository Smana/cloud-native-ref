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
}
