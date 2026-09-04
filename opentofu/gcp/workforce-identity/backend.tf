# GCP state lives in GCS, in a project that holds nothing else.
#
# See opentofu/gcp/network/backend.tf for the full rationale and the bootstrap
# commands, and ADR-0018 for the decision. In short: GCP stacks need GCP
# credentials only, teardown survives an AWS outage, and this stack's state no
# longer sits where an AWS-side compromise could read it.
#
# No `use_lockfile` -- unlike the S3 backend, GCS locks natively.
terraform {
  backend "gcs" {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/workforce-identity"
  }
}
