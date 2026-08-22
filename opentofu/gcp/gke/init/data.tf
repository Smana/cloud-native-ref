# The network stack owns the VPC, the secondary range NAMES that GKE binds to,
# and the control-plane CIDR (which the subnet router must advertise before this
# cluster exists). Consuming its state keeps one source of truth: a secondary
# range renamed here rather than there would force cluster replacement.
data "terraform_remote_state" "network" {
  backend = "gcs"

  config = {
    bucket = "ogenki-435905-tfstate"
    prefix = "cloud-native-ref/gcp/network"
  }
}
