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

# Scaffolding-only: consumed by Task 5 (compute), not by this stack yet.
#tflint-ignore: terraform_unused_declarations
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

# Scaffolding-only: consumed by Task 5 (compute), not by this stack yet.
#tflint-ignore: terraform_unused_declarations
variable "machine_type" {
  description = "GCE machine type for the OpenBao instance(s)"
  type        = string
  default     = "e2-small"
}

# Scaffolding-only: consumed by Task 5 (compute), not by this stack yet.
#tflint-ignore: terraform_unused_declarations
variable "openbao_version" {
  description = "OpenBao version to install on the instance(s)"
  type        = string
}

# Scaffolding-only: consumed by Task 5 (compute), not by this stack yet.
#tflint-ignore: terraform_unused_declarations
variable "data_disk_size_gb" {
  description = "Size in GB of the persistent disk backing OpenBao's raft storage"
  type        = number
  default     = 10
}

variable "server_cert_secret_name" {
  description = "Name of the Secret Manager secret holding the OpenBao server certificate. Created by a different task -- see iam.tf"
  type        = string
  default     = "openbao-priv-gcp-server-cert"
}

# Scaffolding-only: consumed by Task 5 (compute), not by this stack yet.
#tflint-ignore: terraform_unused_declarations
variable "openbao_data_path" {
  description = "Path on the instance's data disk where OpenBao stores its raft data"
  type        = string
  default     = "/opt/openbao/data"
}
