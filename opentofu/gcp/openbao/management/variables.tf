variable "project_id" {
  description = "GCP project holding OpenBao and its secrets"
  type        = string
}

variable "region" {
  description = "GCP region (not the S3 backend's region -- see backend.tf)"
  type        = string
  default     = "europe-west4"
}

variable "private_domain_name" {
  description = "Private domain this PKI issues for. Also builds the OpenBao address."
  type        = string
  default     = "priv.gcp.ogenki.io"
}

variable "openbao_ca_cert_file" {
  description = "Local path to the CA chain used to verify OpenBao's certificate. Written by `openbao-config.sh ca --cloud gcp` before this stack runs; OpenBao's cert comes from the offline root, which no system trust store knows."
  type        = string
  default     = ".tls/ca.pem"
}

variable "root_token_secret_name" {
  description = "GCP Secret Manager entry holding OpenBao's root token, written by `openbao-config.sh init`. Shape is {\"token\": \"...\"}."
  type        = string
  default     = "openbao-priv-gcp-root-token"
}

variable "intermediate_ca_secret_name" {
  description = "GCP Secret Manager entry holding the intermediate CA pem_bundle (certificate + key) from the offline ceremony"
  type        = string
  default     = "openbao-priv-gcp-intermediate-ca"
}

variable "pki_mount_path" {
  description = "Mount path for the PKI engine"
  type        = string
  default     = "pki_private_issuer"
}

variable "pki_common_name" {
  description = "Description on the PKI mount"
  type        = string
  default     = "Ogenki GCP private issuer"
}

variable "pki_organization" {
  description = "Organization on issued certificates. Lowercased, it also names the PKI role the ClusterIssuer references."
  type        = string
  default     = "Ogenki"
}

variable "pki_country" {
  description = "Country on issued certificates"
  type        = string
  default     = "FR"
}

variable "pki_max_lease_ttl" {
  description = "Mount lifetime in seconds. Three years, matching AWS."
  type        = number
  default     = 94608000
}

variable "pki_leaf_ttl" {
  description = "Default lifetime of an issued leaf, in seconds. 90 days: cert-manager renews at two-thirds of lifetime, so this exercises renewal roughly every 60 days."
  type        = number
  default     = 7776000
}

variable "pki_leaf_max_ttl" {
  description = "Maximum leaf lifetime a caller may request, in seconds"
  type        = number
  default     = 7776000
}

variable "ca_chain_secret_name" {
  description = "GCP Secret Manager entry holding the CA chain (root + intermediate certificates, no key). Created by the offline ceremony."
  type        = string
  default     = "openbao-priv-gcp-ca-chain"
}

variable "external_secrets_namespace" {
  description = "Namespace of the External Secrets controller's ServiceAccount. Part of the Workload Identity subject, so it must match the cluster exactly."
  type        = string
  default     = "security"
}

variable "external_secrets_service_account" {
  description = "Name of the External Secrets controller's ServiceAccount. Part of the Workload Identity subject; a mismatch produces a binding the API accepts and that never matches."
  type        = string
  default     = "external-secrets"
}
