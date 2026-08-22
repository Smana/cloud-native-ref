locals {
  network_name = "vpc-${var.region}-${var.env}"
  subnet_name  = "${local.network_name}-nodes"

  # GKE needs stable names for the secondary ranges: gke/init passes these to
  # ip_allocation_policy, and a rename there forces cluster replacement.
  pods_range_name     = "${local.subnet_name}-pods"
  services_range_name = "${local.subnet_name}-services"

  # Routes the subnet router advertises into the shared tailnet.
  #
  # Wider than the AWS side, which advertises only its VPC CIDR. Two additions
  # are deliberate:
  #   - control_plane_cidr, so `kubectl` reaches the PRIVATE GKE endpoint from a
  #     tailnet device (design criterion 5). Without it the endpoint is
  #     unreachable from outside the VPC and the cluster cannot be administered.
  #   - pod_cidr and service_cidr, so Hubble, port-forward-free debugging and
  #     direct Service access work from a laptop the way they do in-cluster.
  advertised_routes = [
    var.node_cidr,
    var.pod_cidr,
    var.service_cidr,
    var.control_plane_cidr,
  ]

  labels = merge(
    { environment = var.env },
    var.tags
  )
}
