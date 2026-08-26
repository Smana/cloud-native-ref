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

variable "approle_secret_name" {
  description = "GCP Secret Manager entry this stack writes cert-manager's AppRole credentials to"
  type        = string
  default     = "openbao-priv-gcp-approle-cert-manager"
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

# CONCERN FOR WHOEVER APPLIES THIS (Task 7): GCP Secret Manager secret IDs may
# only contain letters, numbers, hyphens and underscores -- "/" is invalid.
# The default below is the AWS Secrets Manager name verbatim (slashes and
# all), kept because security/base/openbao-snapshot/external-secrets.yaml's
# `dataFrom.extract.key` is shared, unmodified, across both clouds' overlays
# and must match whatever secret_id this stack actually creates. Every other
# secret in this stack (approle_secret_name, ca_chain_secret_name, ...) uses
# dashes for exactly this reason. Untested against the live API -- `tofu
# validate` does not catch it, only `tofu apply` will. If it 400s, either
# rename this variable's default to a dash-separated ID and add a per-cluster
# ExternalSecret override the way security/gcp-0/openbao/ already does for
# cert-manager's own approle secret, or confirm the API is more permissive
# than documented before assuming that path.
variable "snapshot_approle_secret_name" {
  description = "GCP Secret Manager entry holding the snapshot agent's AppRole credentials and job configuration. Matches the AWS default (var.snapshot_approle_secret_name in opentofu/aws/openbao/management) because security/base/openbao-snapshot/external-secrets.yaml reads this exact key on both clouds."
  type        = string
  default     = "security/openbao/openbao-snapshot"
}

variable "snapshot_bucket_name" {
  description = "GCS bucket where raft snapshots are stored. Empty means derive it from region, matching security/gcp-0/openbao-snapshot/gcs-bucket.yaml's crossplane.io/external-name."
  type        = string
  default     = ""
}
