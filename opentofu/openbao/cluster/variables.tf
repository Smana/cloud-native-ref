variable "env" {
  description = "The environment of the OpenBao cluster"
  type        = string
}

variable "domain_name" {
  description = "The domain name for which the certificate should be issued"
  type        = string
}

variable "mode" {
  description = "OpenBao cluster mode (default dev, meaning a single node)"
  type        = string
  default     = "dev"

  validation {
    condition     = var.mode == "dev" || var.mode == "ha"
    error_message = "The mode must be 'dev' (1 node) or 'ha' (5 nodes)."
  }
}

variable "openbao_version" {
  description = "OpenBao version to install"
  type        = string
  default     = "2.2.0"
}

variable "openbao_data_path" {
  description = "Directory where OpenBao's data will be stored in an EC2 instance"
  type        = string
  default     = "/opt/openbao/data"
}

variable "region" {
  description = "AWS Region"
  default     = "eu-west-3"
  type        = string
}

variable "name" {
  description = "Name of the resources created for this OpenBao cluster"
  default     = "openbao"
  type        = string
}

variable "leader_tls_servername" {
  type        = string
  description = "One of the shared DNS SAN used to create the certs use for mTLS"
}

variable "ami_filter" {
  description = "List of maps used to create the AMI filter for the action runner AMI."
  type        = map(list(string))

  default = {
    name = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

variable "ami_owner" {
  description = "Owner ID of the AMI"
  type        = string

  default = "099720109477" # AWS account ID of Canonical
}

variable "openbao_certificates_secret_name" {
  description = "The name of the AWS Secrets Manager secret containing the OpenBao certificates"
  type        = string
}

variable "enable_ssm" {
  description = "If true, allow to connect to the instances using AWS Systems Manager"
  type        = bool
  default     = false
}

variable "prometheus_node_exporter_enabled" {
  description = "If set to true install and start a prometheus node exporter"
  type        = bool
  default     = false
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
