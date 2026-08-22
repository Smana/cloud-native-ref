variable "env" {
  description = "The environment of the VPC"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "AWS Region"
  default     = "eu-west-3"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+-[0-9]+$", var.region))
    error_message = "Region must be a valid AWS region format (e.g., eu-west-3)."
  }
}

# Network
variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC"
  default     = "10.0.0.0/16"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = split("/", var.vpc_cidr)[1] >= 16 && split("/", var.vpc_cidr)[1] <= 28
    error_message = "VPC CIDR block must have a subnet mask between /16 and /28."
  }
}

variable "pod_cidr" {
  description = "Secondary CIDR block for pod IPs (CG-NAT space 100.64.0.0/10 recommended)"
  default     = "100.64.0.0/16"
  type        = string

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "Pod CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = split("/", var.pod_cidr)[1] >= 10 && split("/", var.pod_cidr)[1] <= 20
    error_message = "Pod CIDR block must have a subnet mask between /10 and /20."
  }
}

variable "private_domain_name" {
  description = "Route53 domain name for private records"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$", var.private_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
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

variable "gcp_routes" {
  description = <<-EOT
    CIDRs advertised into the shared tailnet by the GCP subnet router
    (opentofu/gcp/network). Listed here because the tailnet ACL is a tailnet-wide
    singleton owned by THIS stack, so the GCP stack cannot authorise its own
    routes without the two stacks overwriting each other's ACL on every apply.

    Must stay in sync with `advertised_routes` output of opentofu/gcp/network:
    node, pod, service and GKE control-plane ranges.
  EOT
  type        = list(string)
  default = [
    "10.10.0.0/16",  # nodes
    "100.65.0.0/16", # pods
    "10.11.0.0/20",  # services
    "172.16.0.0/28", # GKE private control plane
  ]

  validation {
    condition     = alltrue([for cidr in var.gcp_routes : can(cidrhost(cidr, 0))])
    error_message = "Every entry in gcp_routes must be a valid IPv4 CIDR block."
  }
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
