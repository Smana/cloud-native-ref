# The network stack owns the VPC, subnet, Cloud DNS private zone and Tailscale
# subnet router. Consuming its state keeps one source of truth for the values
# this stack builds the OpenBao FQDN and node placement from.
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "demo-smana-remote-backend"
    key    = "cloud-native-ref/gcp/network/opentofu.tfstate"
    # The S3 bucket's region, NOT var.region — see backend.tf.
    region = "eu-west-3"
  }
}
