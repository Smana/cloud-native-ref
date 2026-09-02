
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

variable "intermediate_ca_secret_name" {
  description = "AWS Secrets Manager entry holding the intermediate CA pem_bundle ({\"bundle\": \"<cert>\\n<key>\"}) from the offline ceremony. Its private key exists nowhere else on AWS."
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

variable "admin_username" {
  description = "Username for the human operator userpass login, created in the root namespace and carrying both the admin and pki-admin policies"
  type        = string
  default     = "admin"
}

variable "admin_credentials_secret_name" {
  description = "The name of the AWS Secrets Manager secret holding the generated operator password"
  type        = string
  default     = "openbao/cloud-native-ref/users/admin"
}

# Must match `mode` in opentofu/aws/openbao/cluster/variables.tfvars. It duplicates
# one fact across two stacks, which is a drift risk, but the alternative is
# wiring remote state between them for a single flag and this stack has no
# other cross-stack coupling.
#
# Both modes are raft now; `mode` only decides whether autopilot's dead-server
# cleanup is configured (autopilot.tf), which needs the five-node quorum.
variable "mode" {
  description = "Storage mode of the target OpenBao cluster: 'dev' (single-node raft) or 'ha' (five-node raft). Must match the cluster stack."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "ha"], var.mode)
    error_message = "mode must be 'dev' or 'ha'."
  }
}
