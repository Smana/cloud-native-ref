variable "env" {
  description = "The environment of the VPC"
  type        = string
}

variable "region" {
  description = "AWS Region"
  default     = "eu-west-3"
  type        = string
}

# Network
variable "vpc_cidr" {
  description = "The IPv4 CIDR block for the VPC"
  default     = "10.0.0.0/16"
  type        = string
}


variable "tailscale" {
  type = map(string)
  default = {
    subnet_router_name = ""
    api_key            = ""
    tailnet            = ""
  }
}

variable "tags" {
  description = "A map of tags to add to all resources"
  type        = map(string)
  default     = {}
}
