variable "env" {
  description = "The environment of the VPC"
  type        = string
}

variable "region" {
  description = "AWS Region"
  default     = "eu-west-3"
  type        = string
}

# Network
variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC"
  default     = "10.0.0.0/16"
  type        = string
}

variable "private_domain_name" {
  description = "Route53 domain name for private records"
  type        = string
}

variable "tailscale_api_key" {
  description = "Tailscale API Key"
  type        = string
  sensitive   = true
}

variable "tailscale_config" {
  type = map(any)
  default = {
    subnet_router_name = ""
    api_key            = ""
    tailnet            = ""
    prometheus_enabled = false
  }
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
