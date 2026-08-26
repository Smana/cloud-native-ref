# The root token written by `openbao-config.sh init --cloud gcp`.
#
# Shape is {"token": "..."} -- NOT {"root_token": ...}. Reading the wrong key
# and falling back to the whole blob yields
#   configured Vault token contains non-printable characters
# which says nothing about the actual mistake. Measured 2026-08-25.
data "google_secret_manager_secret_version" "openbao_root_token" {
  secret  = var.root_token_secret_name
  project = var.project_id
}

# The openssl-made intermediate: certificate AND private key, as one pem_bundle.
# Created by the offline ceremony (docs/superpowers/specs/2026-08-24-gcp-openbao-design.md),
# never by this stack. The ROOT key is deliberately absent from GCP entirely.
data "google_secret_manager_secret_version" "intermediate_ca" {
  secret  = var.intermediate_ca_secret_name
  project = var.project_id
}

# The network stack owns the VPC and its ranges. Consumed here for one reason:
# both AppRole roles in auth.tf bind `token_bound_cidrs`, and the ranges a gcp-0
# pod may legitimately present to OpenBao's internal LB are the node and pod
# CIDRs, which this stack has no other way to learn.
#
# auth.tf previously claimed these were "already reachable from this stack
# through the network remote state". They were not -- that block lived in
# openbao/cluster/data.tf, the sibling stack, and never here. This adds it,
# mirroring that block verbatim rather than introducing variables: two sources
# for one pair of values is how the stacks drift apart.
data "terraform_remote_state" "network" {
  backend = "gcs"

  config = {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/network"
  }
}
