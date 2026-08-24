variable "gateway_api_version" {
  description = "Gateway API release tag. MUST equal flux/sources/gitrepo-gateway-api.yaml's ref.tag so both clouds run one Gateway API surface"
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.gateway_api_version))
    error_message = "Gateway API version must be a full release tag, e.g. v1.6.1."
  }
}
