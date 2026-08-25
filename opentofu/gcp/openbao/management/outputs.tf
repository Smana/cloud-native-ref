output "pki_mount_path" {
  description = "Mount path of the PKI engine cert-manager issues from"
  value       = vault_mount.pki.path
}

output "cert_manager_role_name" {
  description = "PKI role name cert-manager's ClusterIssuer must reference"
  value       = vault_pki_secret_backend_role.cert_manager.name
}

output "approle_secret_name" {
  description = "GCP Secret Manager entry holding cert-manager's AppRole credentials"
  value       = google_secret_manager_secret.approle_cert_manager.secret_id
}
