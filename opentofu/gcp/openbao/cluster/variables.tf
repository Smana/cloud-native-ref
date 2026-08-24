variable "project_id" {
  description = "GCP project ID hosting the OpenBao cluster"
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
  description = "GCP zone for the OpenBao instance(s)"
  default     = "europe-west4-a"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "Zone must be a valid GCP zone format (e.g., europe-west4-a)."
  }
}

variable "env" {
  description = "The environment of the OpenBao cluster"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

# Name the bootstrap-created KMS key ring/key (see kms.tf) rather than
# deriving them from var.env, so a rename of the environment doesn't silently
# point this stack at a key ring that was never created.
variable "kms_key_ring_name" {
  description = "Name of the pre-existing Cloud KMS key ring holding the auto-unseal key. Created out of band -- see kms.tf"
  type        = string
  default     = "openbao-dev"
}

variable "kms_crypto_key_name" {
  description = "Name of the pre-existing Cloud KMS crypto key used for auto-unseal. Created out of band -- see kms.tf"
  type        = string
  default     = "openbao-unseal"
}

variable "machine_type" {
  description = "GCE machine type for the OpenBao instance(s)"
  type        = string
  default     = "e2-small"
}

variable "openbao_version" {
  description = "OpenBao version to install on the instance(s)"
  type        = string
  # Kept at the latest release. 2.6.x carries openbao/openbao#3411 (inconsistent
  # lock ordering across namespaces, mounts and the router, still OPEN), which
  # deadlocks the core when the management stack writes concurrently — but the
  # concurrency is ours, not OpenBao's. Mirror the AWS mitigation
  # (opentofu/aws/openbao/cluster/variables.tf) if the same symptom shows up
  # here: apply the management stack with -parallelism=1.
  # renovate: datasource=github-releases depName=openbao/openbao
  default = "2.6.2"
}

variable "data_disk_size_gb" {
  description = "Size in GB of the persistent disk backing OpenBao's file storage backend"
  type        = number
  default     = 10
}

variable "server_cert_secret_name" {
  description = "Name of the Secret Manager secret holding the OpenBao server certificate. Created by a different task -- see iam.tf"
  type        = string
  default     = "openbao-priv-gcp-server-cert"
}

variable "openbao_data_path" {
  description = "Path on the instance's data disk where OpenBao's file storage backend keeps its data (single-node, storage \"file\" -- not raft)"
  type        = string
  default     = "/opt/openbao/data"
}

variable "enable_iap_ssh" {
  description = "Open TCP 22 to Google's IAP forwarding range so an operator can SSH to a node whose boot failed. OFF by default: the tailnet already reaches this subnet, and an always-on admin path is a standing exposure."
  type        = bool
  default     = false
}
