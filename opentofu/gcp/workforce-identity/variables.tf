variable "org_id" {
  description = "GCP organisation that owns the workforce pool"
  type        = string
}

variable "workforce_pool_id" {
  description = "Pool id. Embedded in every RBAC group string, and soft-deleted for 30 days -- treat as permanent."
  type        = string
}

variable "identity_provider_url" {
  description = "ZITADEL issuer URL"
  type        = string
}

variable "zitadel_project_id" {
  description = "ZITADEL project id, used as the provider audience"
  type        = string
}

# Derived, never typed. workflows.tm.hcl passes this from
# global.deploy_identity_provider_gcp, which is itself
# `global.primary_cloud == "gcp"`. Setting it in variables.tfvars would override
# the derivation silently and point this pool at the wrong ZITADEL -- the same
# trap gke/configure's copy of this variable warns about. See ADR-0027.
variable "deploy_identity_provider" {
  description = "Whether the GCP cluster hosts its own ZITADEL. Derived from global.primary_cloud by workflows.tm.hcl -- do not set it in variables.tfvars. When true this pool federates auth.<public_domain_name>; when false it federates var.identity_provider_url."
  type        = bool
  default     = false
}

variable "public_domain_name" {
  description = "Public domain of the GCP platform. Only consulted when this cloud hosts the identity provider, to build auth.<domain>."
  type        = string
}
