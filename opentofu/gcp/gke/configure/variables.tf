variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "env" {
  description = "Environment. Substituted into shared manifests as `environment` via the Flux postBuild ConfigMap"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.env)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

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

# These three are REQUIRED, with no defaults, matching
# opentofu/aws/eks/configure/variables.tf. `opentofu/config.tm.hcl` is the single
# source of truth and every script that applies this stack passes all three with
# `-var=`.
#
# A default here would be a second copy of a version that lives somewhere else,
# consulted only when someone runs `tofu` directly in this directory. AWS had
# exactly that and got burned: its defaults said Cilium 1.19.5 / Flux 0.53.0
# while config.tm.hcl had moved to 1.20.0 / 0.55.0, so a direct apply would have
# quietly planned a CNI *downgrade* on a running cluster. The defaults were
# removed there for that reason.
#
# This file had reintroduced them, under a comment claiming "same pattern, and
# same reason, as opentofu/aws/eks/configure" -- which was the opposite of true.
# Required variables make the drift impossible rather than merely discouraged:
# the direct path now fails loudly with "No value for required variable".
variable "cilium_version" {
  description = "Cilium chart version. Required: sourced from globals.cilium_version in opentofu/config.tm.hcl, SHARED with AWS so both clouds upgrade together"
  type        = string
}

variable "flux_operator_version" {
  description = "Flux Operator chart version. Required: sourced from globals.flux_operator_version in opentofu/config.tm.hcl. Shared with AWS"
  type        = string
}

variable "flux_instance_version" {
  description = "Flux Instance chart version. Required: sourced from globals.flux_instance_version in opentofu/config.tm.hcl. Shared with AWS"
  type        = string
}

variable "flux_sync_url" {
  description = "Git repository Flux syncs from"
  type        = string
  default     = "https://github.com/Smana/cloud-native-ref.git"
}

variable "flux_git_ref" {
  description = "Git ref Flux tracks. Override with TF_VAR_flux_git_ref=refs/heads/<branch> to deploy a feature branch"
  type        = string
  default     = "refs/heads/main"
}

variable "flux_github_app_secret_name" {
  description = "GCP Secret Manager secret holding Flux's GitHub App credentials. Deliberately NOT AWS Secrets Manager: reading it from AWS would put a hard AWS dependency in the GCP bootstrap"
  type        = string
  default     = "flux-github-app"
}

variable "gateway_api_version" {
  description = "Gateway API release applied before Cilium. MUST equal flux/sources/gitrepo-gateway-api.yaml's ref.tag so both clouds run one Gateway API surface"
  type        = string
  default     = "v1.6.1"
}

# Federated Route53 path (workstream 12). No defaults on route53_role_arn or
# route53_public_zone_id: both come from opentofu/shared/aws-gcp-federation's
# outputs, and a wrong value here does not fail this apply -- it fails later,
# at certificate issuance, with an AWS error that says nothing about a
# mistyped tfvars entry. Required + no default turns that into a loud
# "No value for required variable" instead.
variable "public_domain_name" {
  description = "Public zone the federated ClusterIssuer solves DNS-01 against, e.g. cloud.ogenki.io. Same variable name and validation as opentofu/aws/eks/configure -- this is the cloud-agnostic zone both clusters write to"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.public_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "route53_public_zone_id" {
  description = "Route53 hosted zone ID for public_domain_name. Sourced from opentofu/shared/aws-gcp-federation's public_zone_id output -- no default"
  type        = string
}

variable "route53_role_arn" {
  description = "AWS IAM role the federated ClusterIssuer and external-dns-public assume via AssumeRoleWithWebIdentity. Sourced from opentofu/shared/aws-gcp-federation's route53_role_arn output -- no default"
  type        = string
}

# NOT var.region: that variable holds gcp-0's GCP region (europe-west4) and has
# other consumers that need exactly that GCP value. cert-manager's route53
# solver feeds its `region` field straight into the AWS SDK's shared config,
# unvalidated, to compute the STS client's endpoint for AssumeRoleWithWebIdentity
# -- reusing var.region would point that client at a nonexistent
# sts.europe-west4.amazonaws.com and break the token exchange this whole
# federation depends on, before Route53 is ever reached. No default, same
# reasoning as route53_role_arn and route53_public_zone_id above.
variable "route53_region" {
  description = "AWS region hint for the federated ClusterIssuer's route53 solver -- an AWS SDK credential-scope value, deliberately separate from var.region (GCP). No default"
  type        = string
}
