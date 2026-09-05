variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "region" {
  description = "AWS Region"
  type        = string
  default     = "eu-west-3"
}

# The three versions below are deliberately REQUIRED — no defaults.
#
# `opentofu/config.tm.hcl` is the single source of truth, and the deploy script
# in `opentofu/aws/eks/init/workflows.tm.hcl` passes all three explicitly with
# `-var=`. A default here would be a second copy of a version that lives
# somewhere else, consulted only when someone runs `tofu` directly in this
# stack.
#
# That is exactly what happened: the defaults said Cilium 1.19.5 and Flux
# 0.53.0 while config.tm.hcl had moved to 1.20.0 and 0.55.0, so a direct
# `tofu apply` here would have quietly planned a CNI *downgrade* on a running
# cluster. The old comment asked for manual sync discipline to prevent it; that
# discipline failed silently, because nothing checks it.
#
# Required variables make the drift impossible instead of merely discouraged:
# the direct path now fails loudly with "No value for required variable" rather
# than planning against a stale version. To use it, pass the values from the
# source of truth, e.g.
#
#   tofu plan -var-file=variables.tfvars \
#     -var="cilium_version=$(hcl2json ../../config.tm.hcl | jq -r .globals.cilium_version)"
#
# or simply run the stack the way it is meant to be run:
#
#   cd opentofu/aws/eks/init && terramate script run deploy

variable "cilium_version" {
  description = "Cilium Helm chart version. Required: sourced from globals.cilium_version in opentofu/config.tm.hcl."
  type        = string
}

variable "flux_operator_version" {
  description = "Flux Operator Helm chart version. Required: sourced from globals.flux_operator_version in opentofu/config.tm.hcl."
  type        = string
}

variable "flux_instance_version" {
  description = "Flux Instance Helm chart version. Required: sourced from globals.flux_instance_version in opentofu/config.tm.hcl."
  type        = string
}

variable "flux_sync_url" {
  description = "Git repository URL for Flux sync"
  type        = string
}

variable "flux_git_ref" {
  description = "Git reference (branch/tag) for Flux sync"
  type        = string
  default     = "refs/heads/main"
}

variable "env" {
  description = "The environment of the EKS cluster"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "gateway_api_version" {
  description = "Gateway API release installed before Cilium. Required: sourced from globals.gateway_api_version in opentofu/config.tm.hcl, SHARED with GCP and with flux/sources/gitrepo-gateway-api.yaml's ref.tag"
  type        = string
}

variable "private_domain_name" {
  description = "Private domain name for internal services (e.g., priv.aws.ogenki.io)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.private_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "public_domain_name" {
  description = "Public domain name for internet-facing services (e.g., cloud.ogenki.io)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.public_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "github_app_secret_name" {
  type        = string
  description = "SecretsManager name from where to retrieve the Github App information. ref: https://fluxcd.io/flux/components/source/gitrepositories/#github"
  default     = "github/flux-app"
  sensitive   = true
}

variable "openbao_root_token_secret_id" {
  description = "Secrets Manager entry holding the OpenBao root token ({\"token\": ...}), used by the vault provider to create this cluster's JWT auth mount"
  type        = string
  default     = "openbao/cloud-native-ref/tokens/root"
  sensitive   = true
}

variable "openbao_ca_cert_file" {
  description = "CA chain used to verify OpenBao's server certificate. Written by `openbao-config.sh ca` in the deploy workflow; .tls/ is gitignored."
  type        = string
  default     = ".tls/ca.pem"
}

variable "openbao_jwt_audience" {
  description = "Audience every ServiceAccount token presented to OpenBao must carry. Consumers request it via serviceAccountRef.audiences / a projected token's audience."
  type        = string
  default     = "openbao"
}

# Which OpenBao this cluster's pods reach through the neutral `openbao` Service,
# when the overlay lists security/base/openbao-endpoint/remote. In the normal
# posture aws-0 lists the local form and this is unused -- but the key still has
# to reach the cluster's ConfigMap, or Flux substitutes an empty string into the
# Service's tailnet-ip annotation, which is schema-valid and silently wrong.
#
# EMPTY by default, unlike the gcp-0 counterpart, and the asymmetry is real
# rather than an oversight: gcp-0 can default to the AWS NLB's address because
# that address is FIXED (opentofu/aws/openbao/cluster/load_balancer.tf assigns
# it with cidrhost, and outputs it as nlb_private_ips). The GCP internal load
# balancer's address is allocated dynamically -- google_compute_address.openbao
# sets no `address` -- so there is no value to write here until that stack has
# been applied. The failback runbook reads it from that stack's `internal_ip`
# output (opentofu/gcp/openbao/cluster/outputs.tf).
variable "openbao_target_ip" {
  description = "Private address of the OpenBao this cluster consumes, for the remote form of the openbao Service. Empty in the normal posture; set from the GCP cluster stack's internal_ip output during a failback."
  type        = string
  default     = ""
}
