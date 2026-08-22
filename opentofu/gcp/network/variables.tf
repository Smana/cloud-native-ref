variable "env" {
  description = "The environment of the VPC"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_id" {
  description = "GCP project ID hosting the network"
  type        = string
}

variable "region" {
  description = "GCP region"
  default     = "europe-west4"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "Region must be a valid GCP region format (e.g., europe-west4)."
  }
}

variable "zone" {
  description = "GCP zone for zonal resources (the Tailscale subnet router, and later the GKE control plane)"
  default     = "europe-west4-a"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone format (e.g., europe-west4-a)."
  }
}

# Network
#
# Both clusters join the SAME tailnet, so a range collision with AWS does not fail
# loudly -- it breaks subnet routing in a way that presents as a Cilium bug. AWS
# holds VPC 10.0.0.0/16 and pods 100.64.0.0/16.
#
# OpenTofu has no CIDR-containment function, so these validations are prefix
# guards against a careless edit, not a general overlap proof. The authoritative
# check is the Python one in the plan's Task 3 Step 2, re-run whenever a range
# changes or the AWS side advertises a new one.
variable "node_cidr" {
  description = "Primary IPv4 range of the node subnet"
  default     = "10.10.0.0/16"
  type        = string

  validation {
    condition     = can(cidrhost(var.node_cidr, 0))
    error_message = "Node CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = !startswith(var.node_cidr, "10.0.")
    error_message = "Node CIDR must not overlap the AWS VPC range 10.0.0.0/16 advertised into the same tailnet."
  }
}

variable "pod_cidr" {
  description = "Secondary range for pod IPs. Must not collide with the AWS pod range 100.64.0.0/16"
  default     = "100.65.0.0/16"
  type        = string

  validation {
    condition     = can(cidrhost(var.pod_cidr, 0))
    error_message = "Pod CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = !startswith(var.pod_cidr, "100.64.")
    error_message = "Pod CIDR must not overlap the AWS pod range 100.64.0.0/16 advertised into the same tailnet."
  }
}

variable "service_cidr" {
  description = "Secondary range for Kubernetes Service ClusterIPs"
  default     = "10.11.0.0/20"
  type        = string

  validation {
    condition     = can(cidrhost(var.service_cidr, 0))
    error_message = "Service CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = !startswith(var.service_cidr, "10.0.")
    error_message = "Service CIDR must not overlap the AWS VPC range 10.0.0.0/16 advertised into the same tailnet."
  }
}

variable "control_plane_cidr" {
  description = "IPv4 range for the private GKE control plane. Defined here rather than in gke/init because the subnet router must advertise it into the tailnet before the cluster exists; gke/init consumes it as an output"
  default     = "172.16.0.0/28"
  type        = string

  validation {
    condition     = can(cidrhost(var.control_plane_cidr, 0))
    error_message = "Control plane CIDR must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = split("/", var.control_plane_cidr)[1] == "28"
    error_message = "GKE requires the control plane range to be exactly a /28."
  }
}

variable "private_domain_name" {
  description = "Cloud DNS private zone name for GCP-side records"
  type        = string
  default     = "priv.gcp.cloud.ogenki.io"

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$", var.private_domain_name))
    error_message = "Private domain name must be a valid DNS name."
  }
}

variable "tailscale_api_key" {
  description = "Tailscale API key used to manage the tailnet ACL and auth keys"
  type        = string
  sensitive   = true
}

variable "tailscale_config" {
  description = "Tailscale subnet router configuration"
  type = object({
    subnet_router_name = string
    tailnet            = string
    machine_type       = optional(string, "e2-micro")
  })
}

variable "tags" {
  description = "Labels applied to every resource that supports them"
  type        = map(string)
  default     = {}
}
