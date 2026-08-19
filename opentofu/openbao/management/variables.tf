
variable "region" {
  description = "The region to deploy the resources"
  type        = string
}

variable "openbao_root_token_secret_id" {
  description = "The secret ID for the OpenBao root token"
  type        = string
}

variable "domain_name" {
  description = "The domain name for which the certificate should be issued"
  type        = string
}

variable "openbao_domain_name" {
  description = "Vault domain name (default: bao.<domain_name>)"
  type        = string
  default     = ""
}

variable "openbao_ca_cert_file" {
  description = "Path to the CA chain used to verify the OpenBao server certificate. Written by `openbao-config.sh ca` in the deploy workflow, from the root CA secret in AWS Secrets Manager. Relative to the stack directory; .tls/ is gitignored."
  type        = string
  default     = ".tls/ca.pem"
}

variable "openbao_skip_tls_verify" {
  description = "Disable TLS verification when talking to OpenBao. Escape hatch for a first bootstrap where the CA chain is not yet in Secrets Manager - leave false for every normal run."
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to reach Vault's API"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "root_ca_secret_name" {
  description = "The name of the AWS Secrets Manager secret containing the root CA certificate bundle"
  type        = string
}

variable "cert_manager_approle_secret_name" {
  description = "The name of the AWS Secrets Manager secret containing the cert-manager AppRole credentials"
  type        = string
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
  description = "Maximum TTL (in seconds) for the mount and the intermediate issuer (default 3 years)"
  type        = number
  default     = 94670856
}

variable "pki_leaf_ttl" {
  description = "Default TTL (in seconds) for issued leaf certificates (default 30 days)"
  type        = number
  default     = 2592000
}

variable "pki_leaf_max_ttl" {
  description = "Maximum TTL (in seconds) a caller may request for a leaf certificate (default 90 days)"
  type        = number
  default     = 7776000
}

variable "snapshot_approle_secret_name" {
  description = "The name of the AWS Secrets Manager secret holding the snapshot agent's AppRole credentials and job configuration"
  type        = string
  default     = "security/openbao/openbao-snapshot"
}

variable "recovery_keys_secret_name" {
  description = "The name of the AWS Secrets Manager secret holding the OpenBao recovery keys. Referenced by the snapshot job's restore path; the job's IAM role deliberately cannot read it (restore is an operator action)."
  type        = string
  default     = "openbao/cloud-native-ref/tokens/recovery"
}

variable "snapshot_bucket_name" {
  description = "S3 bucket where raft snapshots are stored"
  type        = string
  default     = ""
}

variable "admin_username" {
  description = "Username for the human operator userpass logins, created in both the `admin` and `admin/pki` namespaces"
  type        = string
  default     = "admin"
}

variable "admin_credentials_secret_name" {
  description = "The name of the AWS Secrets Manager secret holding the generated operator passwords for both namespaces"
  type        = string
  default     = "openbao/cloud-native-ref/users/admin"
}
