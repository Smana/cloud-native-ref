variable "env" {
  description = "Environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

# NOTE: there is deliberately no `project_number` variable.
#
# It is derived from data.google_project.this.number (see data.tf). It used to be
# a required input duplicating a value GCP already knows, which created the
# opportunity for exactly the mistake this stack warns about elsewhere: the
# NUMBER and the ID are not interchangeable, they occupy different segments of
# the Workload Identity principal string, and swapping them produces a binding
# the API accepts and that silently never matches.

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west4"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gcp-0"
}

variable "kubernetes_version" {
  description = "GKE control plane version. 'latest' tracks the channel default"
  type        = string
  default     = "latest"
}

variable "release_channel" {
  description = "GKE release channel"
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE", "UNSPECIFIED"], var.release_channel)
    error_message = "Release channel must be RAPID, REGULAR, STABLE or UNSPECIFIED."
  }
}

variable "node_image_type" {
  description = "Node image. The autoscaling plan (slice 4) must pin the SAME value on every ComputeClass, or autoscaled nodes differ in kernel capability from the static pool"
  type        = string
  default     = "COS_CONTAINERD"
}

variable "node_machine_type" {
  description = "Static pool machine type. A GKE node pool accepts exactly ONE type, so the AWS 6-way spot diversification does not port -- keep the static pool small and let ComputeClass supply breadth"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Static pool size. Matches the EKS bootstrap group's min_size = 2"
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Static pool ceiling. Matches the EKS bootstrap group's max_size = 3"
  type        = number
  default     = 3
}

variable "node_disk_size_gb" {
  description = "Boot disk size for static pool nodes"
  type        = number
  default     = 50
}

variable "tags" {
  description = "Labels applied to resources that support them"
  type        = map(string)
  default     = {}
}

# ── Node auto-provisioning ceiling ──────────────────────────────────────────
# Design criterion 16: cluster resourceLimits are set, and an oversized workload
# stays Unschedulable at the ceiling rather than growing the cluster to fit it.
#
# Deliberately small. This is a reference platform that gets rebuilt, so the cost
# of a limit that is too LOW is an Unschedulable pod and a one-line change; the
# cost of one that is too HIGH is a bill nobody notices until it arrives.
#
# The static pool is 2-3 x e2-standard-4 (4 vCPU / 16 GiB each), so this leaves
# room for roughly four more comparable nodes before the ceiling bites.
#
# IMPORTANT: this ceiling is CLUSTER-WIDE. GKE counts manually created pools
# toward it, not just auto-provisioned ones, and it is shared across every
# ComputeClass. With the static pool at its max of 3 nodes (12 vCPU / 48 GiB),
# only 20 vCPU remain for general-purpose, io and gpu-l4 combined.
#
# The consequence worth knowing: `gpu_resources` maximum 2 (2 x g2-standard-4 =
# 8 vCPU) is reachable only while the other classes stay under 12 vCPU. A GPU
# scale-up can therefore be starved by CPU scale-up, and the two are
# indistinguishable from the events -- both simply fail to provision. Raise this
# ceiling before relying on GPU capacity under load.
variable "autoscaling_max_cpu_cores" {
  description = "Total vCPU ceiling across all auto-provisioned node pools"
  type        = number
  default     = 32
}

variable "autoscaling_max_memory_gb" {
  description = "Total memory ceiling in GiB across all auto-provisioned node pools"
  type        = number
  default     = 128
}
