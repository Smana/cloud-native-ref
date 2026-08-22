output "project_id" {
  description = "GCP project hosting the network"
  value       = var.project_id
}

output "region" {
  description = "GCP region of the network"
  value       = var.region
}

output "zone" {
  description = "GCP zone used for zonal resources"
  value       = var.zone
}

output "network_name" {
  description = "Name of the VPC"
  value       = module.vpc.network_name
}

output "network_id" {
  description = "ID of the VPC, consumed by gke/init"
  value       = module.vpc.network_id
}

output "network_self_link" {
  description = "Self-link of the VPC"
  value       = module.vpc.network_self_link
}

output "nodes_subnetwork_name" {
  description = "Name of the node subnet, consumed by gke/init"
  value       = local.subnet_name
}

output "nodes_subnetwork_self_link" {
  description = "Self-link of the node subnet"
  value       = module.vpc.subnets_self_links[0]
}

# GKE references its secondary ranges by NAME. Renaming either forces cluster
# replacement, so these outputs are the contract between this stack and gke/init.
output "pods_range_name" {
  description = "Name of the pod secondary range"
  value       = local.pods_range_name
}

output "services_range_name" {
  description = "Name of the Service secondary range"
  value       = local.services_range_name
}

output "node_cidr" {
  description = "Primary CIDR of the node subnet"
  value       = var.node_cidr
}

output "pod_cidr" {
  description = "Pod secondary CIDR. gke/configure needs this for Cilium's ipv4NativeRoutingCIDR, which is mandatory under routingMode=native + ipam=kubernetes"
  value       = var.pod_cidr
}

output "service_cidr" {
  description = "Service secondary CIDR"
  value       = var.service_cidr
}

output "control_plane_cidr" {
  description = "Private GKE control plane range. Owned here because the subnet router advertises it before the cluster exists; gke/init must consume this rather than redeclare it"
  value       = var.control_plane_cidr
}

output "advertised_routes" {
  description = "Routes the subnet router advertises into the tailnet. Each must be permitted by the AWS-owned tailnet ACL to be usable"
  value       = local.advertised_routes
}

output "private_domain_name" {
  description = "Cloud DNS private zone domain"
  value       = var.private_domain_name
}

output "private_dns_zone_name" {
  description = "Cloud DNS managed-zone resource name, consumed by external-dns and cert-manager later"
  value       = module.private_dns.name
}

output "tailscale_subnet_router_name" {
  description = "Name of the Tailscale subnet router instance"
  value       = google_compute_instance.tailscale_subnet_router.name
}
