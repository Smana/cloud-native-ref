variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-3"
}

variable "models_bucket_name" {
  description = "Name of the existing S3 bucket holding model weights (created by Crossplane via the SQLInstance/llm-models-bucket composition)."
  type        = string
  default     = "eu-west-3-ogenki-llm-models"
}

variable "filesystem_name" {
  description = "Name of the S3 Files filesystem"
  type        = string
  default     = "llm-models-fs"
}

variable "cluster_name" {
  description = "EKS cluster name — used to discover the worker-node security group via tags"
  type        = string
  default     = "mycluster-0"
}

variable "tags" {
  description = "Common AWS tags applied to every resource"
  type        = map(string)
  default = {
    project   = "cloud-native-ref"
    component = "llm-platform"
    managedby = "OpenTofu"
  }
}
