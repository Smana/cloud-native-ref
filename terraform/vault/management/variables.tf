variable "domain_name" {
  description = "The domain name for which the certificate should be issued"
  type        = string
}

variable "vault_domain_name" {
  description = "Vault domain name (default: vault.<domain_name>)"
  type        = string
  default     = ""
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to reach Vault's API"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "pki_common_name" {
  description = "Common name to identify the Vault issuer"
  type        = string
  default     = "Private PKI - Vault Issuer"
}

variable "pki_mount_path" {
  description = "Vault Issuer PKI mount path"
  type        = string
  default     = "pki_private_issuer"
}

variable "pki_organization" {
  description = "The organization name used for generating certificates"
  type        = string
}

variable "pki_country" {
  description = "The country name used for generating certificates"
  type        = string
}

variable "pki_domains" {
  description = "List of domain names that can be used within the certificates"
  type        = list(string)
  default     = ["cluster.local"]
}

variable "pki_key_type" {
  description = "The generated key type"
  type        = string
  default     = "ec"
}

variable "pki_key_bits" {
  description = "The number of bits of generated keys"
  type        = number
  default     = 256
}

variable "pki_max_lease_ttl" {
  description = "Maximum TTL (in seconds) that can be requested for certificates (default 3 years)"
  type        = number
  default     = 94670856
}
