provider "google" {
  project = var.project_id
  region  = var.region
}

# This provider needs a REACHABLE, INITIALISED OpenBao at plan time, which is
# the entire reason this stack is split from openbao/cluster -- the same
# constraint that splits gke/init from gke/configure.
#
# The CA file is not optional in practice: OpenBao's certificate is issued by
# the offline root, which no system trust store knows about. `terramate script
# run deploy` writes it first via
#   scripts/openbao-config.sh ca --cloud gcp ...
# See workflows.tm.hcl.
provider "vault" {
  address      = local.openbao_address
  token        = jsondecode(data.google_secret_manager_secret_version.openbao_root_token.secret_data)["token"]
  ca_cert_file = var.openbao_ca_cert_file
}
