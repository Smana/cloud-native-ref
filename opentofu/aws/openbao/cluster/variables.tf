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
  # Kept at the latest release. 2.6.x carries openbao/openbao#3411 (inconsistent
  # lock ordering across namespaces, mounts and the router, still OPEN), which
  # deadlocks the core when the management stack writes concurrently — but the
  # concurrency is ours, not OpenBao's. The management stack now applies with
  # -parallelism=1 (opentofu/aws/openbao/management/workflows.tm.hcl), which clears
  # it; see the reproduction recorded there. Do not raise that parallelism while
  # #3411 is open.
  # renovate: datasource=github-releases depName=openbao/openbao
  default = "2.6.2"
}

variable "openbao_data_path" {
  description = "Directory where OpenBao's data will be stored in an EC2 instance"
  type        = string
  default     = "/opt/openbao/data"
}

variable "seal_key_alias" {
  description = "Alias of the seal key this node unseals with. MUST match `seal_key_alias` in opentofu/aws/openbao/lineage, which creates it -- nothing enforces that, and a mismatch surfaces as a plan-time 'alias not found'."
  type        = string
  default     = "alias/openbao-seal"
}

variable "root_volume_size" {
  description = "Size (GiB) of the encrypted gp3 root volume. In dev mode this also holds the single-node raft store, so it needs headroom beyond the AMI default of 8."
  type        = number
  default     = 20
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
