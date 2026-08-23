# Private Cloud DNS zone for GCP-side records.
#
# A SIBLING zone to the AWS side's priv.aws.ogenki.io rather than a shared one:
# the two clouds resolve through different resolvers (Route53 private zone vs
# Cloud DNS private zone) and sharing a name would need cross-cloud forwarding
# for no benefit while both clusters are independent. external-dns on the GCP
# cluster owns records under this zone only.
module "private_dns" {
  # checkov:skip=CKV_TF_1:Version-pinned like every other registry module here.
  source  = "terraform-google-modules/cloud-dns/google"
  version = "~> 7.0"

  project_id = var.project_id
  type       = "private"
  name       = replace(var.private_domain_name, ".", "-")
  domain     = "${var.private_domain_name}."

  private_visibility_config_networks = [module.vpc.network_self_link]

  labels = local.labels
}
