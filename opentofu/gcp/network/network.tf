# VPC, node subnet and the two GKE secondary ranges.
#
# Mirrors the AWS side's use of terraform-aws-modules/vpc rather than hand-rolled
# resources. One subnet in one region: the cluster is zonal (design criterion 9),
# and the AWS bootstrap node group is likewise pinned to a single subnet "for
# costs reasons".
module "vpc" {
  # checkov:skip=CKV_TF_1:Pinned by version constraint, not commit hash, matching
  # every other registry module in this repo including the AWS ones. Changing it
  # here alone would be inconsistent without being safer.
  source  = "terraform-google-modules/network/google"
  version = "~> 18.1"

  project_id   = var.project_id
  network_name = local.network_name

  # REGIONAL keeps Cloud Router advertisements scoped to this region. GLOBAL (the
  # module default) would advertise across every region the VPC ever spans, which
  # this single-region design never needs.
  routing_mode = "REGIONAL"

  subnets = [
    {
      subnet_name   = local.subnet_name
      subnet_ip     = var.node_cidr
      subnet_region = var.region

      # Private Google Access: nodes without external IPs reach Google APIs over
      # Google's internal fabric instead of egressing through Cloud NAT. This is
      # one of the two GCP-only cost levers in the design -- without it, every
      # call to container.googleapis.com, GCS and Artifact Registry bills as NAT
      # traffic. It is also what lets the nodes stay private.
      subnet_private_access = "true"

      # Flow logs mirror the AWS side, which enables VPC flow logs on its VPC.
      subnet_flow_logs          = "true"
      subnet_flow_logs_sampling = "0.5"
      subnet_flow_logs_metadata = "INCLUDE_ALL_METADATA"
    },
  ]

  # Keyed by subnet name. GKE consumes these by NAME, not by CIDR -- see
  # local.pods_range_name / local.services_range_name.
  secondary_ranges = {
    (local.subnet_name) = [
      {
        range_name    = local.pods_range_name
        ip_cidr_range = var.pod_cidr
      },
      {
        range_name    = local.services_range_name
        ip_cidr_range = var.service_cidr
      },
    ]
  }
}
