# The GCP lineage owns the node's service account (stable unique ID, trusted by
# the AWS seal role) and the snapshot bucket. This stack reads both.
data "terraform_remote_state" "lineage" {
  backend = "gcs"

  config = {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/openbao/lineage"
  }
}

locals {
  lineage = data.terraform_remote_state.lineage.outputs
}
