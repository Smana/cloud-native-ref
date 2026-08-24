variable "tailscale_api_key" {
  description = "Tailscale API key"
  type        = string
  sensitive   = true
}

variable "tailnet" {
  description = "Tailscale tailnet name"
  type        = string
}

variable "admin_users" {
  description = "Members of group:admin, which is the only group allowed to reach tag:admin services such as Hubble UI"
  type        = list(string)
}

variable "advertised_routes" {
  description = <<-EOT
    Every CIDR any subnet router advertises into this tailnet, across all clouds.

    Passed as a variable rather than read from the cloud stacks' state on
    purpose: those stacks depend on THIS one (a route is advertised but unusable
    until autoApprovers permits it), so reading their state here would make the
    dependency circular. The CIDRs are static plan inputs anyway.

    Must stay in sync with:
      opentofu/aws/network  vpc_cidr
      opentofu/gcp/network  advertised_routes output
  EOT
  type        = map(list(string))

  validation {
    condition     = alltrue([for _, cidrs in var.advertised_routes : alltrue([for c in cidrs : can(cidrhost(c, 0))])])
    error_message = "Every advertised route must be a valid IPv4 CIDR block."
  }
}

variable "search_domains" {
  description = "DNS search paths for the whole tailnet. A LIST, and tailnet-wide: every cloud's private domain must appear here or its names do not resolve from a tailnet device"
  type        = list(string)
}

# No split_dns_domains input here on purpose: split-DNS is per-domain, so each
# cloud's network stack owns its own google_dns_policy / Route53 resolver, which
# is where the resolver address actually lives.
