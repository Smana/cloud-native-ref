
variable "region" {
  description = "The region to deploy the resources"
  type        = string
}

variable "openbao_root_token_secret_id" {
  description = "The secret ID for the OpenBao root token"
  type        = string
}

variable "domain_name" {
  description = "The domain name for which the certificate should be issued"
  type        = string
}

variable "openbao_domain_name" {
  description = "Vault domain name (default: bao.<domain_name>)"
  type        = string
  default     = ""
}

variable "openbao_ca_cert_file" {
  description = "Path to the CA chain used to verify the OpenBao server certificate. Written by `openbao-config.sh ca` in the deploy workflow, from the ca-chain secret (certificates/priv.aws.ogenki.io/ca-chain, certificates only) in AWS Secrets Manager. Relative to the stack directory; .tls/ is gitignored."
  type        = string
  default     = ".tls/ca.pem"
}

variable "openbao_skip_tls_verify" {
  description = "Disable TLS verification when talking to OpenBao. Escape hatch for a first bootstrap where the CA chain is not yet in Secrets Manager - leave false for every normal run."
  type        = bool
  default     = false
}

variable "allowed_cidr_blocks" {
  description = "List of CIDR blocks allowed to reach Vault's API"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}

variable "intermediate_ca_secret_name" {
  description = "AWS Secrets Manager entry holding the intermediate CA pem_bundle ({\"bundle\": \"<cert>\\n<key>\"}) from the offline ceremony. Its private key exists nowhere else on AWS."
  type        = string
}

variable "pki_common_name" {
  description = "Common name to identify the Vault issuer"
  type        = string
  default     = "Private PKI - Vault Issuer"
}

variable "pki_mount_path" {
  description = "Vault Issuer PKI mount path"
  type        = string
  default     = "pki_private_issuer"
}

variable "pki_organization" {
  description = "The organization name used for generating certificates"
  type        = string
}

variable "pki_country" {
  description = "The country name used for generating certificates"
  type        = string
}

variable "pki_domains" {
  description = "List of domain names that can be used within the certificates"
  type        = list(string)
  default     = ["cluster.local"]
}

variable "pki_max_lease_ttl" {
  description = "Maximum TTL (in seconds) for the mount and the leases issued from it (default 3 years). The intermediate's own lifetime comes from the offline signing ceremony, not this variable."
  type        = number
  default     = 94670856
}

# 30 days on BOTH clouds, and the two knobs are deliberately different values.
# This one is only what a caller gets when it requests no duration of its own;
# pki_leaf_max_ttl below is the cap. Keeping the default well under the cap is
# the point of having both: a caller that has not thought about lifetime gets a
# short certificate, and one that needs longer has to ask.
#
# It is behaviour-neutral today. The only Certificate issued by this role is
# infrastructure/base/gapi/platform-private-gateway-certificate.yaml, which
# asks for `duration: 2160h` (90 d, i.e. exactly the cap) with
# `renewBefore: 360h`, so it never sees this default. GCP used to set this to
# 90 d as well, making default == cap and quietly handing every future caller
# the maximum; its comment also justified the value by a renewal cadence that
# the Certificate's own duration decides, not this variable.
#
# Shortening the leaf lifetime that is actually issued means changing that
# Certificate's `duration` -- a behaviour change, and a separate decision.
variable "pki_leaf_ttl" {
  description = "Default lifetime of an issued leaf, in seconds, for a caller that requests none (30 days). A caller may ask for up to pki_leaf_max_ttl."
  type        = number
  default     = 2592000
}

variable "pki_leaf_max_ttl" {
  description = "Maximum TTL (in seconds) a caller may request for a leaf certificate (default 90 days)"
  type        = number
  default     = 7776000
}

variable "admin_username" {
  description = "Username for the human operator userpass login, created in the root namespace and carrying both the admin and pki-admin policies"
  type        = string
  default     = "admin"
}

variable "admin_credentials_secret_name" {
  description = "The name of the AWS Secrets Manager secret holding the generated operator password"
  type        = string
  default     = "openbao/cloud-native-ref/users/admin"
}

# Must match `mode` in opentofu/aws/openbao/cluster/variables.tfvars. It duplicates
# one fact across two stacks, which is a drift risk, but the alternative is
# wiring remote state between them for a single flag and this stack has no
# other cross-stack coupling.
#
# Both modes are raft now; `mode` only decides whether autopilot's dead-server
# cleanup is configured (autopilot.tf), which needs the five-node quorum.
variable "mode" {
  description = "Storage mode of the target OpenBao cluster: 'dev' (single-node raft) or 'ha' (five-node raft). Must match the cluster stack."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "ha"], var.mode)
    error_message = "mode must be 'dev' or 'ha'."
  }
}

# ZITADEL OIDC for human operators (ADR-0034)
# -------------------------------------------
# Empty disables the OIDC auth method entirely, which is the right state for a
# cluster whose ZITADEL has not been bootstrapped yet. There is a genuine
# ordering knot: `zitadel-oidc-clients.sh` must run before there is a client to
# configure, that script needs a running ZITADEL, and ZITADEL needs secrets from
# this stack. Gating on the value rather than trying to order the two lets a
# first deploy converge without OIDC and pick it up on the next apply.
variable "openbao_oidc_secret_id" {
  description = "AWS Secrets Manager secret holding {client_id, client_secret, endpoint} for OpenBao's ZITADEL OIDC client, as written by scripts/zitadel-oidc-clients.sh. Empty disables OIDC auth."
  type        = string
  default     = ""
}

variable "openbao_oidc_issuer" {
  description = "ZITADEL issuer URL. Defaults to the `endpoint` field of openbao_oidc_secret_id, so it normally needs no value."
  type        = string
  default     = ""
}
