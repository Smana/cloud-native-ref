# subnetwork_self_link and fqdn are consumed by compute.tf (Task 5).
# private_dns_zone and private_domain_name remain scaffolding-only, kept for
# Task 6 (load balancer / PKI), so this stack references the network stack's
# outputs through one name instead of re-deriving them.
locals {
  network = data.terraform_remote_state.network.outputs

  subnetwork_self_link = local.network.nodes_subnetwork_self_link
  #tflint-ignore: terraform_unused_declarations
  private_dns_zone = local.network.private_dns_zone_name
  #tflint-ignore: terraform_unused_declarations
  private_domain_name = local.network.private_domain_name
  fqdn                = "bao.${local.network.private_domain_name}"
}
