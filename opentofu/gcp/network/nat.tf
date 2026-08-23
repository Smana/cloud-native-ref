# Cloud NAT exists ONLY for genuine external egress -- public container
# registries, Helm chart hosts, the Tailscale coordination server. Google API
# traffic does NOT come through here: Private Google Access on the node subnet
# (see network.tf) carries it over Google's internal fabric at no NAT cost.
#
# Nodes have no external IPs, so without this they cannot pull a public image.
module "cloud_nat" {
  # checkov:skip=CKV_TF_1:Version-pinned like every other registry module here.
  source  = "terraform-google-modules/cloud-nat/google"
  version = "~> 7.0"

  project_id = var.project_id
  region     = var.region
  name       = "nat-${var.region}-${var.env}"

  # The module creates the Cloud Router too; there is no pre-existing one to
  # attach to in a fresh project.
  create_router = true
  router        = "router-${var.region}-${var.env}"
  network       = module.vpc.network_name

  # ALL_SUBNETWORKS_ALL_IP_RANGES covers the pod secondary range as well as the
  # node primary. Pods egress to the internet directly under Cilium native
  # routing, so NATting only the primary range would break every pod-initiated
  # pull.
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config_enable = true
  log_config_filter = "ERRORS_ONLY"
}
