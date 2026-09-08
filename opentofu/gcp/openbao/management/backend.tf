# GCP state lives in GCS, in a project that holds nothing else.
#
# See opentofu/gcp/network/backend.tf for the full rationale and the bootstrap
# commands, and ADR-0018 for the decision. In short: GCP stacks now need GCP
# credentials only, teardown survives an AWS outage, and this stack's state no
# longer sits where an AWS-side compromise could read it.
#
# No `use_lockfile` -- unlike the S3 backend, GCS locks natively.
#
# This stack's state is the one that most needed moving: the vault provider
# reads OpenBao's live root token straight out of Secret Manager (see
# providers.tf), and that token's value flows into this state.
terraform {
  backend "gcs" {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/openbao/management"
  }
}
