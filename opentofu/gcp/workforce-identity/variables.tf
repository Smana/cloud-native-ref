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
