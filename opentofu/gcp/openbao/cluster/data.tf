# The network stack owns the VPC, subnet, Cloud DNS private zone and Tailscale
# subnet router. Consuming its state keeps one source of truth for the values
# this stack builds the OpenBao FQDN and node placement from.
data "terraform_remote_state" "network" {
  backend = "gcs"

  config = {
    bucket = "ogenki-cloud-native-ref-tfstate"
    prefix = "cloud-native-ref/gcp/network"
  }
}
