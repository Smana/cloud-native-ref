provider "google" {
  project = var.project_id
  region  = var.region
}

# The cluster already exists (created by gke/init in a SEPARATE apply), so these
# providers configure from remote state and a data source rather than from
# resources being created in this same apply. That split is the whole reason the
# bootstrap is two stages -- see opentofu/gcp/gke/init/versions.tf.
#
# The control-plane endpoint is PRIVATE, so this stack must run from a machine on
# the tailnet, exactly like its EKS counterpart.
provider "helm" {
  kubernetes = {
    host                   = "https://${local.cluster_endpoint}"
    cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

provider "kubectl" {
  apply_retry_count      = 15
  host                   = "https://${local.cluster_endpoint}"
  cluster_ca_certificate = base64decode(local.cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
  load_config_file       = false
}

# OpenBao, for this cluster's JWT auth mount (openbao.tf). Root token from
# Secret Manager, CA chain written to .tls/ by the deploy workflow first.
provider "vault" {
  address      = "https://bao.${local.init.private_domain_name}:8200"
  token        = jsondecode(data.google_secret_manager_secret_version.openbao_root_token.secret_data)["token"]
  ca_cert_file = var.openbao_ca_cert_file
}
