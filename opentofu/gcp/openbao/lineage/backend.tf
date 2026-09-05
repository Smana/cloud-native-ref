# GCP state lives in GCS -- see opentofu/gcp/network/backend.tf and ADR-0018.
terraform {
  backend "gcs" {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/openbao/lineage"
  }
}
