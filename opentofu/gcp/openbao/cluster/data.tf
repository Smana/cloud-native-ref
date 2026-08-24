# Scaffolding-only: not consumed by any resource in THIS stack yet. Task 5
# (compute) shipped without needing the project number. Kept for Task 6 (load
# balancer / DNS) or the management stack's PKI work, which may still need it
# for API calls the project ID alone can't address; remove if neither ends up
# using it.
#tflint-ignore: terraform_unused_declarations
data "google_project" "this" {
  project_id = var.project_id
}

# The network stack owns the VPC, subnet, Cloud DNS private zone and Tailscale
# subnet router. Consuming its state keeps one source of truth for the values
# this stack builds the OpenBao FQDN and node placement from.
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "demo-smana-remote-backend"
    key    = "cloud-native-ref/gcp/network/opentofu.tfstate"
    # Literal, NOT var.region: this is the S3 bucket's region, while var.region
    # in this stack is a GCP region (europe-west4).
    region = "eu-west-3"
  }
}
