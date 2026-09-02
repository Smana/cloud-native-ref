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
  description = "Gateway API release applied before Cilium. Required: sourced from globals.gateway_api_version in opentofu/config.tm.hcl, SHARED with AWS and with flux/sources/gitrepo-gateway-api.yaml's ref.tag"
  type        = string
}

# Federated Route53 path (ADR-0019). No defaults on route53_role_arn or
# route53_public_zone_id: both come from opentofu/shared/aws-gcp-federation's
# outputs, and a wrong value here does not fail this apply -- it fails later,
# at certificate issuance, with an AWS error that says nothing about a
# mistyped tfvars entry. Required + no default turns that into a loud
# "No value for required variable" instead.
#
# public_domain_name is `gcp.cloud.ogenki.io`, NOT `cloud.ogenki.io` -- a
# deliberate departure from the AWS variable of the same name, added after the
# final-branch review: aws-0 already runs a live wildcard Certificate for
# `*.cloud.ogenki.io`. A gcp-0 requesting the identical identifier set would
# share Let's Encrypt's Duplicate Certificate limit (5/week, not exempted for
# renewals, counted across accounts) with aws-0's production renewal, and both
# clusters would race to write the same `_acme-challenge.cloud.ogenki.io` TXT
# record. Giving gcp-0 its own subdomain closes both, and matches the
# private-domain precedent this repo already set (`priv.aws.ogenki.io` vs
# `priv.gcp.ogenki.io`) -- only the public name had collided. See ADR-0019.
variable "public_domain_name" {
  description = "Public name the federated ClusterIssuer solves DNS-01 against and the Gateway serves: gcp.cloud.ogenki.io, a subdomain of the shared zone -- deliberately NOT the same value as opentofu/aws/eks/configure's variable of the same name. See the comment above and ADR-0019"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.public_domain_name))
    error_message = "Domain name must be a valid DNS domain name."
  }
}

variable "route53_public_zone_id" {
  description = "Route53 hosted zone ID of the PARENT zone (cloud.ogenki.io) that contains public_domain_name -- there is no separate delegated zone for the gcp.cloud.ogenki.io subdomain. Sourced from opentofu/shared/aws-gcp-federation's public_zone_id output -- no default"
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
# -- reusing var.region would point that client at a region that does not exist
# in AWS (e.g. sts.europe-west4.amazonaws.com) and break the token exchange this
# whole federation depends on, before Route53 is ever reached. No default, same
# reasoning as route53_role_arn and route53_public_zone_id above.
variable "route53_region" {
  description = "AWS region hint for the federated ClusterIssuer's route53 solver -- an AWS SDK credential-scope value, deliberately separate from var.region (GCP). No default"
  type        = string
}

# The platform's identity provider, which gcp-0 CONSUMES rather than hosts.
#
# The identity provider: hosted here, or consumed from elsewhere.
#
# ADR-0024 supersedes ADR-0022. The IdP is no longer a singleton by decision --
# it is deployable on either cloud, defaulting to AWS, so a GCP-only platform
# does not need an AWS cluster running to log anyone in. What stays AWS-owned is
# PUBLIC DNS (Route53, ADR-0019): `auth.<public domain>` on this cluster
# resolves through the same cross-cloud federation as every other public
# hostname here.
#
# ADR-0027 settles what "deployable on either cloud" means: ZITADEL is a
# primary-cloud SINGLETON. It relocates to whichever cloud is primary; two
# clouds each running one is ruled out, because a grant means nothing without
# knowing which directory issued it.
#
# DO NOT SET THIS IN variables.tfvars. It is derived from global.primary_cloud
# and passed as `-var` by workflows.tm.hcl on every invocation -- deploy,
# preview, destroy and drift -- and a trailing `-var` wins over `-var-file`.
# A literal in the tfvars file is therefore silently ineffective. Setting
# primary_cloud is what flips this.
#
# TWO GATES still, but only one is typed:
#
#   1. deploy_identity_provider (here) -- DERIVED, drives identity_provider_url,
#      which every consumer reads.
#   2. clusters/gcp-0/security/zitadel.yaml `spec.suspend` -- committed Flux
#      state, which Terramate cannot reach. VERIFIED against primary_cloud by
#      ./scripts/validate-idp-topology.sh in CI.
#
# The default stays false so that a bare `tofu apply` run in this directory,
# outside the Terramate workflow, cannot stand up a second directory by
# omission.
variable "deploy_identity_provider" {
  description = "Whether this cluster hosts its own ZITADEL. Derived from global.primary_cloud by workflows.tm.hcl -- do not set it in variables.tfvars, where a `-var` would override it silently. False consumes the instance named by identity_provider_url. See ADR-0027"
  type        = bool
  default     = false
}

# Only consulted when deploy_identity_provider is false. A full URL rather than
# a hostname because both consumers -- apps/base/openwebui's OIDC discovery
# document and tooling/base/homepage's link -- need the scheme.
variable "identity_provider_url" {
  description = "Base URL of the identity provider to CONSUME when this cluster does not host one. Defaults to the aws-0 instance; ignored when deploy_identity_provider is true"
  type        = string
  default     = "https://auth.cloud.ogenki.io"

  validation {
    condition     = can(regex("^https://[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.identity_provider_url))
    error_message = "identity_provider_url must be an https:// URL with no path or trailing slash."
  }
}

# Workforce pool federating ZITADEL (opentofu/gcp/workforce-identity). Substituted
# into the gcp-0 RBAC bindings; an empty value silently produces a binding
# matching nobody.
variable "workforce_pool_id" {
  description = "Workforce pool federating ZITADEL. Substituted into the gcp-0 RBAC bindings; an empty value silently produces a binding matching nobody."
  type        = string
}
