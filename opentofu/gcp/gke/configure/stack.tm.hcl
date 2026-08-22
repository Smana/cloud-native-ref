stack {
  name        = "GKE Cluster - Configure"
  description = "Gateway API CRDs, then Cilium, then Flux Operator and Flux Instance"
  id          = "c47b81e0-3f92-4a15-b6d8-9e02a7c5d431"

  after = [
    "/opentofu/gcp/gke/init"
  ]

  tags = [
    "gcp",
    "gke",
    "kubernetes",
    "infrastructure"
  ]
}
