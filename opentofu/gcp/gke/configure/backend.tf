terraform {
  backend "gcs" {
    bucket = "ogenki-435905-tfstate"
    prefix = "cloud-native-ref/gcp/gke/configure"
  }
}
