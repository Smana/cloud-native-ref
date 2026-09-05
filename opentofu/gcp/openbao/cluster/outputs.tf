output "endpoint" {
  description = "OpenBao API endpoint. Reachable from the tailnet; TLS verifies only against this NAME, never the IP."
  value       = "https://${local.fqdn}:8200"
}

output "fqdn" {
  description = "OpenBao's DNS name, matching the server certificate's only SAN"
  value       = local.fqdn
}

output "internal_ip" {
  description = "Load balancer address. For diagnostics only -- connecting here by IP cannot verify TLS, by design."
  value       = google_compute_address.openbao.address
}

output "service_account_email" {
  description = "The OpenBao node's service account"
  value       = local.lineage.openbao_node_sa_email
}
