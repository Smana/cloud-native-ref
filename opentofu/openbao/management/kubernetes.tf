# Secret required for Flux variables substitutions
resource "kubernetes_secret" "cert_manager_openbao_approle" {
  metadata {
    name      = "cert-manager-openbao-approle"
    namespace = "flux-system"
  }
  data = {
    "cert_manager_role_id"   = vault_approle_auth_backend_role.cert_manager.role_id
    "cert_manager_secret_id" = vault_approle_auth_backend_role_secret_id.cert_manager.secret_id
  }
}
