variable "pki_mount_path" {
  description = "The PKI mount this OpenBao issues from. Templated into the pki-admin policy so the policy cannot drift from the mount it governs."
  type        = string
}

variable "openbao_address" {
  description = "https://bao.<private domain>:8200. Builds the OIDC UI callback, which must match what scripts/zitadel-oidc-clients.sh registers."
  type        = string
}

variable "admin_username" {
  description = "Username of the userpass break-glass login"
  type        = string
  default     = "admin"
}

variable "admin_group_alias" {
  description = "The value in the token's `groups` claim that maps to openbao-admin. It is the access matrix's platform team."
  type        = string
  default     = "platform"
}

variable "secret_owning_apps" {
  description = "Apps that own a prefix under apps/. Each gets a policy, an external identity group and an alias (ADR-0036). Only created when OIDC is configured, because the alias is bound to the OIDC mount."
  type        = set(string)
  default     = []
}

variable "oidc_client_id" {
  description = "ZITADEL client id for OpenBao's OIDC login. Empty disables OIDC, so a first deploy converges before ZITADEL exists."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "ZITADEL client secret for OpenBao's OIDC login"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_issuer" {
  description = "ZITADEL issuer URL. Empty disables OIDC."
  type        = string
  default     = ""
}
