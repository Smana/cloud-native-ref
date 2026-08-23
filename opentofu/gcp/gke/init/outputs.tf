output "cluster_name" {
  description = "GKE cluster name"
  value       = module.gke.name
}

output "cluster_endpoint" {
  description = "Private control-plane endpoint, consumed by gke/configure"
  value       = module.gke.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate, consumed by gke/configure"
  value       = module.gke.ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Cluster location (the zone, since this cluster is zonal)"
  value       = module.gke.location
}

output "project_id" {
  description = "GCP project hosting the cluster"
  value       = var.project_id
}

output "region" {
  description = "GCP region"
  value       = var.region
}

output "workload_pool" {
  description = "Workload Identity pool, <project-id>.svc.id.goog"
  value       = module.gke.identity_namespace
}

output "crossplane_principal" {
  description = "Crossplane's Workload Identity principal. Surfaced so the NUMBER/ID split is visible in the plan output rather than discovered as a permission error that points nowhere"
  value       = local.crossplane_principal
}

# gke/configure needs this for Cilium's ipv4NativeRoutingCIDR, which is MANDATORY
# under routingMode=native + ipam.mode=kubernetes. AWS ENI mode derives it; GKE
# cannot, and the agent exits 255 without it. Verified by the Phase 1 gate.
output "pod_cidr" {
  description = "Pod CIDR, required by Cilium's ipv4NativeRoutingCIDR on GCP"
  value       = local.net.pod_cidr
}

# The rest are re-exported from the network stack so gke/configure can build the
# Flux postBuild-substitution ConfigMap without reading a second remote state.
# That ConfigMap is how cluster-specific values reach shared manifests under
# infrastructure/, security/ and observability/.

output "project_number" {
  description = "GCP project number. Distinct from project_id and NOT interchangeable with it"
  value       = var.project_number
}

output "network_name" {
  description = "VPC name"
  value       = local.net.network_name
}

output "node_cidr" {
  description = "Node subnet CIDR"
  value       = local.net.node_cidr
}

output "service_cidr" {
  description = "Service secondary CIDR"
  value       = local.net.service_cidr
}

output "private_domain_name" {
  # $${...} escapes the interpolation: an unescaped ${private_domain_name} here
  # is read as an HCL variable reference and fails with "Variables not allowed".
  # Same escaping rule as the Grafana dashboard JSON in this repo.
  description = "Cloud DNS private zone domain, substituted into manifests as $${private_domain_name}"
  value       = local.net.private_domain_name
}
