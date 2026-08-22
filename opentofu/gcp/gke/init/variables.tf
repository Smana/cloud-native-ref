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

variable "project_number" {
  description = <<-EOT
    GCP project NUMBER, not the ID.

    Required for the Workload Identity principal string, where the two are NOT
    interchangeable and sit in different segments:

      principal://iam.googleapis.com/projects/<NUMBER>/locations/global/
        workloadIdentityPools/<PROJECT_ID>.svc.id.goog/subject/ns/<NS>/sa/<KSA>

    Reversed, the API accepts the binding and it simply never matches -- a
    permission error that points nowhere.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "Project number must be numeric. The project ID is not a substitute."
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west4"
}

variable "zone" {
  description = "Zone for the cluster and its static node pool. A single zone mirrors the AWS bootstrap node group's single-subnet choice and avoids cross-zone egress charges"
  type        = string
  default     = "europe-west4-a"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "gcp-mycluster-0"
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
