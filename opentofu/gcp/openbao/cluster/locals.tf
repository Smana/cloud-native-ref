# One name for the network stack's outputs, so this stack does not re-derive
# values the network stack already owns — the VPC, subnet, Cloud DNS private
# zone and Tailscale subnet router all live there.
locals {
  network = data.terraform_remote_state.network.outputs

  subnetwork_self_link = local.network.nodes_subnetwork_self_link
  fqdn                 = "bao.${local.network.private_domain_name}"
}
