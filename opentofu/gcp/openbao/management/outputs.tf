output "pki_mount_path" {
  description = "Mount path of the PKI engine cert-manager issues from"
  value       = vault_mount.pki.path
}

output "cert_manager_role_name" {
  description = "PKI role name cert-manager's ClusterIssuer must reference"
  value       = vault_pki_secret_backend_role.cert_manager.name
}
