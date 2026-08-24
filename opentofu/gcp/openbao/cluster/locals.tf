# Scaffolding-only: none of these are consumed by a resource in THIS stack yet.
# They exist so Tasks 5/6 (compute, load balancer, PKI) can reference the
# network stack's outputs through one name instead of re-deriving them.
locals {
  network = data.terraform_remote_state.network.outputs

  #tflint-ignore: terraform_unused_declarations
  subnetwork_self_link = local.network.nodes_subnetwork_self_link
  #tflint-ignore: terraform_unused_declarations
  private_dns_zone = local.network.private_dns_zone_name
  #tflint-ignore: terraform_unused_declarations
  private_domain_name = local.network.private_domain_name
  #tflint-ignore: terraform_unused_declarations
  fqdn = "bao.${local.network.private_domain_name}"
}
