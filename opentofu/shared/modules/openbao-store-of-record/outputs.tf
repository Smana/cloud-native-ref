output "admin_password" {
  description = "The break-glass userpass password. The caller publishes it to its own cloud's secret store."
  value       = random_password.admin.result
  sensitive   = true
}

output "platform_mount_path" {
  description = "Path of the platform/ kv-v2 mount"
  value       = vault_mount.platform.path
}

output "apps_mount_path" {
  description = "Path of the apps/ kv-v2 mount"
  value       = vault_mount.apps.path
}

output "policy_names" {
  description = "The four policies this module defines, by the names other states reference"
  value = [
    vault_policy.admin.name,
    vault_policy.pki_admin.name,
    vault_policy.secrets_admin.name,
    vault_policy.external_secrets.name,
  ]
}

output "oidc_enabled" {
  description = "1 when the OIDC login is configured, 0 otherwise"
  value       = local.oidc_on
}
