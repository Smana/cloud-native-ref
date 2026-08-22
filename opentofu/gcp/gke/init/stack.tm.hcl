stack {
  name        = "GKE Cluster - Init"
  description = "GKE Standard cluster (zonal, private, legacy datapath), static spot node pool, Workload Identity, Crossplane WIF bootstrap"
  id          = "5a0ec1d9-6b2f-4f8e-9c3a-7d41e0b8f256"

  after = [
    "/opentofu/gcp/network"
  ]

  tags = [
    "gcp",
    "gke",
    "kubernetes",
    "infrastructure"
  ]
}
